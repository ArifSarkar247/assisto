import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_community_api.dart';
import '../../state.dart';
import '../../theme.dart';

/// Assisto Messenger — COMMUNITY privacy settings (Step 3, item 5).
///
/// Two server-enforced controls:
///   1. "Who in my communities can message me" — Everyone (default) or Nobody.
///      NOBODY blocks even the message-request creation (read into
///      can_direct_message server-side). The client only expresses the choice.
///   2. "Show my phone to community members" — opt-in; default OFF. Phone stays
///      hidden on member cards unless this is on (member_card / set_show_phone).
///
/// Backend: PATCH /me/communities-who-can-msg, PATCH /me/show-phone,
///          GET /me/communities-who-can-msg (current values).
class CommunitySettingsScreen extends StatefulWidget {
  const CommunitySettingsScreen({super.key});

  @override
  State<CommunitySettingsScreen> createState() =>
      _CommunitySettingsScreenState();
}

class _CommunitySettingsScreenState extends State<CommunitySettingsScreen> {
  bool _loading = true;

  // Default EVERYONE (per spec).
  String _whoCanMsg = 'everyone';
  // Default hidden (opt-in).
  bool _showPhone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final r = await _api.communitiesWhoCanMsg();
      _whoCanMsg = '${r['who_can_msg'] ?? 'everyone'}';
      _showPhone = r['show_phone'] == true;
    } catch (_) {
      // keep safe defaults
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setWhoCanMsg(String value) async {
    final prev = _whoCanMsg;
    setState(() => _whoCanMsg = value);
    try {
      await _api.setCommunitiesWhoCanMsg(value);
    } catch (_) {
      if (mounted) setState(() => _whoCanMsg = prev);
    }
  }

  Future<void> _setShowPhone(bool value) async {
    final prev = _showPhone;
    setState(() => _showPhone = value);
    try {
      await _api.setShowPhone(value);
    } catch (_) {
      if (mounted) setState(() => _showPhone = prev);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.communitySettingsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                _sectionHeader(_t.communityWhoCanMessageTitle, scheme),
                RadioListTile<String>(
                  value: 'everyone',
                  groupValue: _whoCanMsg,
                  title: Text(_t.communityWhoEveryone),
                  subtitle: Text(_t.communityWhoEveryoneHint),
                  onChanged: (v) => _setWhoCanMsg(v!),
                ),
                RadioListTile<String>(
                  value: 'nobody',
                  groupValue: _whoCanMsg,
                  title: Text(_t.communityWhoNobody),
                  subtitle: Text(_t.communityWhoNobodyHint),
                  onChanged: (v) => _setWhoCanMsg(v!),
                ),
                const Divider(),
                _sectionHeader(_t.communityPhoneTitle, scheme),
                SwitchListTile(
                  secondary: const Icon(Icons.phone_rounded),
                  title: Text(_t.communityShowPhone),
                  subtitle: Text(_t.communityShowPhoneHint),
                  value: _showPhone,
                  onChanged: _setShowPhone,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_rounded,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          _t.communitySettingsServerNote,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                              height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.primary)),
      );
}
