import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Reusable privacy-control widgets for the Connected Circle privacy screen.
///
/// These mirror the SERVER-ENFORCED decision functions in
/// core/logic/circle_privacy.py. The server is authoritative; these widgets are
/// the UI that edits the stored policy (POST back to the backend, which then
/// enforces on every read/message/call). Changing them client-side only changes
/// the *request* — the server still decides. No Bangla literals; labels come
/// from AppLocalizations (lib/l10n).

/// Audience policy values — keep in lock-step with circle_privacy.VIS_* and
/// CALLS_* machine codes (ASCII, stored).
class CirclePrivacyCodes {
  CirclePrivacyCodes._();
  // visibility
  static const visEveryone = 'everyone';
  static const visFamily = 'family';
  static const visNobody = 'nobody';

  /// calls-presence: WhatsApp "My contacts" — only people I saved back.
  static const visContacts = 'contacts';

  /// Fields that offer Everyone / My contacts / Family / Nobody (presence);
  /// the others keep My circle / Family / Nobody.
  static const presenceFields = ['last_seen', 'active_status'];
  static const visFields = [
    'last_seen',
    'active_status',
    'profile_photo',
    'about',
    'status',
  ];
  // incoming-call policy
  static const callsEveryone = 'everyone';
  static const callsChosen = 'chosen';
  static const callsRelations = 'relations';
  static const callsNobody = 'nobody';
}

/// A single visibility field with a segmented everyone/family/nobody choice.
class CircleVisibilityRow extends StatelessWidget {
  final String field; // one of CirclePrivacyCodes.visFields
  final String value; // current policy
  final ValueChanged<String> onChanged;
  const CircleVisibilityRow({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
  });

  String _fieldLabel(AppLocalizations t) {
    switch (field) {
      case 'last_seen':
        return t.circlePrivacyLastSeen;
      case 'active_status':
        return t.circlePrivacyActiveStatus;
      case 'profile_photo':
        return t.circlePrivacyProfilePhoto;
      case 'about':
        return t.circlePrivacyAbout;
      case 'status':
        return t.circlePrivacyStatusVisibility;
      default:
        return field;
    }
  }

  bool get _isPresence => CirclePrivacyCodes.presenceFields.contains(field);

  /// calls-presence: last seen / online — WhatsApp's Everyone / My contacts /
  /// Nobody (+ the existing Family only). Chips WRAP on a narrow phone or a
  /// large font, so no label is ever clipped.
  Widget _presenceChoices(BuildContext context, AppLocalizations t) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.xs,
        children: [
          for (final (v, l) in [
            (CirclePrivacyCodes.visEveryone, t.cpPrivEveryone),
            (CirclePrivacyCodes.visContacts, t.cpPrivMyContacts),
            (CirclePrivacyCodes.visFamily, t.cpPrivFamilyOnly),
            (CirclePrivacyCodes.visNobody, t.circlePrivacyAudienceNobody),
          ])
            ChoiceChip(
              key: Key('cp-vis-$field-$v'),
              label: Text(l),
              selected: value == v,
              onSelected: (_) => onChanged(v),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_isPresence) {
      return Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_fieldLabel(t),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            _presenceChoices(context, t),
            if (value == CirclePrivacyCodes.visNobody)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(
                    field == 'last_seen'
                        ? t.cpPrivLastSeenReciprocal
                        : t.cpPrivOnlineReciprocal,
                    key: Key('cp-recip-$field'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_fieldLabel(t),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          // QA a6: full width, one line per label (scaled to fit) — at 1.5x
          // "My circle" wrapped and was clipped by the pill's rounded corner.
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final (v, l) in [
                (CirclePrivacyCodes.visEveryone, t.circlePrivacyAudienceCircle),
                (CirclePrivacyCodes.visFamily, t.circlePrivacyAudienceFamily),
                (CirclePrivacyCodes.visNobody, t.circlePrivacyAudienceNobody),
              ])
                ButtonSegment(
                    value: v,
                    label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l, maxLines: 1, softWrap: false))),
            ],
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          ),
        ],
      ),
    );
  }
}

/// A labelled on/off switch row (read receipts, typing, DND family exception).
class CirclePrivacyToggle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;
  const CirclePrivacyToggle({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon = Icons.tune,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Incoming-call policy selector (everyone / chosen / relations / nobody).
class CircleCallPolicySelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const CircleCallPolicySelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final options = <String, String>{
      CirclePrivacyCodes.callsEveryone: t.circleCallPolicyEveryone,
      CirclePrivacyCodes.callsChosen: t.circleCallPolicyChosen,
      CirclePrivacyCodes.callsRelations: t.circleCallPolicyRelations,
      CirclePrivacyCodes.callsNobody: t.circleCallPolicyNobody,
    };
    return Column(
      children: [
        for (final e in options.entries)
          RadioListTile<String>(
            value: e.key,
            groupValue: value,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            title: Text(e.value),
          ),
      ],
    );
  }
}

/// A row that triggers block / restrict / report actions on a member.
class CircleSafetyActions extends StatelessWidget {
  final bool blocked;
  final bool restricted;
  final VoidCallback onToggleBlock;
  final VoidCallback onToggleRestrict;
  final VoidCallback onReport;
  const CircleSafetyActions({
    super.key,
    required this.blocked,
    required this.restricted,
    required this.onToggleBlock,
    required this.onToggleRestrict,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.block, color: scheme.error),
          title: Text(blocked ? t.circleUnblock : t.circleBlock),
          subtitle: Text(t.circleBlockExplainer),
          onTap: onToggleBlock,
        ),
        ListTile(
          leading: const Icon(Icons.visibility_off_outlined),
          title:
              Text(restricted ? t.circleUnrestrict : t.circleRestrict),
          subtitle: Text(t.circleRestrictExplainer),
          onTap: onToggleRestrict,
        ),
        ListTile(
          leading: Icon(Icons.flag_outlined, color: scheme.error),
          title: Text(t.circleReport),
          subtitle: Text(t.circleReportExplainer),
          onTap: onReport,
        ),
      ],
    );
  }
}
