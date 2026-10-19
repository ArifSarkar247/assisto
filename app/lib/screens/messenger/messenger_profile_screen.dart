import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/profile_avatar_editor.dart';
import 'msgr_set_privacy_screen.dart';

/// The Messenger profile — ADVANCED (SPEC v2.1 §21, #98): photo (pick / crop /
/// change / remove via image_picker), display name, about/bio, phone (shown
/// per privacy), and per-field visibility hints that link to the Messenger
/// Privacy hub. Reads `/me`, writes via the core typed PATCH /me
/// (`api.updateProfile(fields)`), reusing the `User.photo` field (migration
/// 0025). Honest loading / saving / error states; save-time validation.
///
/// ORIGINAL identity: Assisto gradient header, our own icons/wording. ZERO
/// Bangla glyphs live in this file — every string comes from the ARB
/// (AppLocalizations).
class MessengerProfileScreen extends StatefulWidget {
  const MessengerProfileScreen({super.key});

  @override
  State<MessengerProfileScreen> createState() =>
      _MessengerProfileScreenState();
}

class _MessengerProfileScreenState extends State<MessengerProfileScreen> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = true;
  bool _loadError = false;
  bool _saving = false;
  String _phone = '';
  String? _photoB64; // null = untouched, '' = removed, else new base64
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
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final me = await _api.messengerProfile();
      _name.text = '${me['name'] ?? ''}';
      _about.text = '${me['bio'] ?? me['about'] ?? ''}';
      _phone = '${me['phone'] ?? ''}';
      _existingPhoto =
          '${me['photo_url'] ?? me['photo_link'] ?? ''}';
      _phoneVisibility = _norm('${me['show_phone'] ?? 'circle'}');
      _communitiesWhoCanMsg =
          _norm('${me['communities_who_can_msg'] ?? 'circle'}');
    } catch (_) {
      // Fall back to the cached user; if even that is missing, show the honest
      // load-error state with a retry.
      final u = context.read<AppState>().user;
      if (u == null) {
        if (mounted) setState(() => _loadError = true);
      } else {
        _name.text = u.name;
        _phone = u.phone ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _norm(String v) {
    if (v == 'everyone' || v == 'circle' || v == 'true') return 'circle';
    if (v == 'family') return 'family';
    if (v == 'nobody' || v == 'none' || v == 'false') return 'nobody';
    return 'circle';
  }

  String get _currentPhoto => _photoB64 ?? _existingPhoto; // '' means removed

  String? _validateName(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return AppLocalizations.of(context).pfNameRequired;
    if (s.length > 60) return AppLocalizations.of(context).pfNameTooLong;
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
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
      // Call the API directly so a failure is surfaced honestly (AppState's
      // saveProfile swallows errors). The response is authoritative — it
      // carries the stored, cache-busted photo_url — so adopt it straight into
      // AppState.user. That refreshes the Settings profile card + every avatar
      // immediately, with ONE upload (no fire-and-forget re-send).
      final updated = await _api.updateProfile(fields);
      if (mounted) {
        context.read<AppState>().setUser(updated);
        // Mirror the saved photo back into the editor so it shows the stored
        // URL (not just the local base64) and survives a reopen.
        _existingPhoto = updated.photoUrl;
        _photoB64 = null;
      }
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

  void _openPrivacy() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MsgrSetPrivacyScreen()));

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrProfileTitle)),
      body: _loading
          ? _LoadingState()
          : _loadError
              ? _LoadErrorState(onRetry: _load)
              : _form(context, t),
    );
  }

  Widget _form(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
        children: [
          // ---- photo (pick / crop / change / remove + initial fallback) ----
          ProfileAvatarEditor(
            name: _name.text,
            currentPhoto: _currentPhoto,
            onChanged: (v) => setState(() => _photoB64 = v),
          ),
          const SizedBox(height: Gap.lg),

          // ---- name (validated) ----
          Text(t.msgrDisplayName, style: titleStyle),
          const SizedBox(height: Gap.xs),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: _validateName,
            onChanged: (_) => setState(() {}), // keeps avatar initial in sync
            maxLength: 60,
            decoration: InputDecoration(
              hintText: t.msgrDisplayName,
              helperText: AppLocalizations.of(context).pfNameHelper,
            ),
          ),
          const SizedBox(height: Gap.sm),

          // ---- about / bio ----
          Text(t.msgrAbout, style: titleStyle),
          const SizedBox(height: Gap.xs),
          TextFormField(
            controller: _about,
            minLines: 2,
            maxLines: 4,
            maxLength: 140,
            decoration: InputDecoration(hintText: t.msgrAboutHint),
          ),
          const SizedBox(height: Gap.xs),
          Text(AppLocalizations.of(context).pfNameVisibilityNote,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),

          // ---- phone (shown per privacy) ----
          Text(t.msgrPhone, style: titleStyle),
          const SizedBox(height: Gap.xs),
          if (_phone.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.phone_outlined, color: scheme.onSurfaceVariant),
              title: Text(_phone),
            )
          else
            Text(AppLocalizations.of(context).pfPhoneHidden,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),

          // ---- per-field visibility (hint + link to Privacy hub) ----
          _PrivacyHintCard(
            hint: AppLocalizations.of(context).pfVisibilityHint,
            action: AppLocalizations.of(context).pfOpenPrivacy,
            onTap: _openPrivacy,
          ),
          const SizedBox(height: Gap.md),

          Text(t.msgrPhoneVisibility, style: titleStyle),
          const SizedBox(height: Gap.xs),
          _visibilityPicker(
              _phoneVisibility, (v) => setState(() => _phoneVisibility = v)),
          const SizedBox(height: Gap.lg),
          Text(t.msgrWhoCanMessage, style: titleStyle),
          const SizedBox(height: Gap.xs),
          _visibilityPicker(_communitiesWhoCanMsg,
              (v) => setState(() => _communitiesWhoCanMsg = v)),
          const SizedBox(height: Gap.xl),

          // ---- save (honest saving state) ----
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: Gap.sm),
                      Text(AppLocalizations.of(context).pfSaving),
                    ],
                  )
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

class _LoadingState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: Gap.md),
        Text(AppLocalizations.of(context).pfLoading,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _LoadErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadErrorState({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, size: 48, color: scheme.error),
          const SizedBox(height: Gap.md),
          Text(AppLocalizations.of(context).pfLoadError,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(AppLocalizations.of(context).pfLoadErrorBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          FilledButton.tonal(onPressed: onRetry, child: Text(t.retry)),
        ]),
      ),
    );
  }
}

/// Per-field visibility hint that links to the Messenger Privacy hub. Keeps the
/// profile editor the single place to launch field-level privacy controls.
class _PrivacyHintCard extends StatelessWidget {
  final String hint;
  final String action;
  final VoidCallback onTap;
  const _PrivacyHintCard(
      {required this.hint, required this.action, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hint,
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(action,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary)),
                  ]),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}
