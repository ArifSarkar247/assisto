import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'contacts_match_model.dart';
import 'msgr_avatar.dart';

/// c1-contacts — presentation pieces for the WhatsApp-style contacts screen.
/// Pure widgets (no API); the screen wires callbacks. No hard-coded copy.

/// My Circle relationship of a found Assisto user, from the server's
/// `circle.state` (none | pending | incoming | accepted).
enum C1CircleState { none, pending, incoming, accepted }

C1CircleState c1CircleStateOf(Map<String, dynamic> user) {
  final c = user['circle'];
  final s = c is Map ? '${c['state'] ?? 'none'}' : 'none';
  switch (s) {
    case 'accepted':
      return C1CircleState.accepted;
    case 'pending':
      return C1CircleState.pending;
    case 'incoming':
      return C1CircleState.incoming;
    default:
      return C1CircleState.none;
  }
}

// ---------------------------------------------------------------------------
// Prominent disclosure — shown BEFORE the OS permission prompt (Play policy).
// ---------------------------------------------------------------------------
class C1Disclosure extends StatelessWidget {
  const C1Disclosure({
    super.key,
    required this.onAllow,
    required this.onDeny,
    required this.onPrivacy,
  });

  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const Key('c1-disclosure'),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, gradient: Brand.gradient),
            child: const Icon(Icons.contacts_outlined,
                color: Colors.white, size: 36),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.c1DisclosureTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.md),
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_outline, color: scheme.onPrimaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.c1DisclosureLead,
                  style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                      height: 1.4)),
            ),
          ]),
        ),
        const SizedBox(height: Gap.md),
        _fact(context, Icons.help_outline, 'cmDiscWhyTitle', 'cmDiscWhyBody'),
        _fact(context, Icons.delete_outline, 'cmDiscStoreTitle',
            'cmDiscStoreBody'),
        _fact(context, Icons.tune, 'cmDiscControlTitle', 'cmDiscControlBody'),
        const SizedBox(height: Gap.xs),
        Text(t.c1DisclosureNextStep,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        TextButton.icon(
          onPressed: onPrivacy,
          icon: const Icon(Icons.shield_outlined, size: 18),
          label: Text(cmLabel(context, 'cmPrivacyLearnMore')),
        ),
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const Key('c1-allow'),
          onPressed: onAllow,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(t.msgrContactsAllow),
        ),
        const SizedBox(height: Gap.xs),
        TextButton(onPressed: onDeny, child: Text(t.msgrContactsDeny)),
      ]),
    );
  }

  Widget _fact(BuildContext c, IconData icon, String title, String body) {
    final scheme = Theme.of(c).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: scheme.primary, size: 22),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cmLabel(c, title),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(cmLabel(c, body),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Honest "couldn't read contacts on this phone" banner (no reader / the OS
// refused to start it).
// ---------------------------------------------------------------------------
class C1InfoBanner extends StatelessWidget {
  const C1InfoBanner(
      {super.key, required this.title, required this.body, this.icon});

  final String title;
  final String body;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? Icons.info_outline, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer)),
            const SizedBox(height: 2),
            Text(body,
                style: TextStyle(
                    color: scheme.onSecondaryContainer, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------
class C1SectionHeader extends StatelessWidget {
  const C1SectionHeader(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color ?? Theme.of(context).colorScheme.primary)),
      );
}

// ---------------------------------------------------------------------------
// On-Assisto row: Add to My Circle / Requested / Accept / Message + Call.
// Buttons sit in a Wrap under the name so nothing clips at 360 px or with a
// large font.
// ---------------------------------------------------------------------------
class C1AssistoUserRow extends StatelessWidget {
  const C1AssistoUserRow({
    super.key,
    required this.user,
    this.contactName = '',
    this.busy = false,
    required this.onAdd,
    required this.onAccept,
    required this.onMessage,
    required this.onCall,
  });

  final Map<String, dynamic> user;
  final String contactName;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback onAccept;
  final VoidCallback onMessage;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = '${user['name'] ?? ''}'.trim();
    final shown = contactName.isNotEmpty ? contactName : name;
    final state = c1CircleStateOf(user);
    final sub = <String>[
      if (contactName.isNotEmpty && name.isNotEmpty && name != contactName)
        t.c1OnAssistoAs(name),
      if (state == C1CircleState.accepted) t.c1InYourCircle,
      if (state == C1CircleState.pending) t.mr1CallsAfterAccept, // mr1
      if (state == C1CircleState.incoming) t.c1WantsToConnect,
    ];
    final actions = <Widget>[
      if (state == C1CircleState.none)
        FilledButton.icon(
          key: Key('c1-add-${user['id']}'),
          onPressed: busy ? null : onAdd,
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: Text(t.c1AddToCircle),
        ),
      // mr1: WhatsApp-like — anyone on Assisto can be messaged at once (a
      // message request until they accept; calls open after).
      if (state == C1CircleState.none || state == C1CircleState.pending)
        FilledButton.tonalIcon(
          key: Key('mr1-msg-${user['id']}'),
          onPressed: busy ? null : onMessage,
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: Text(t.c1Message),
        ),
      if (state == C1CircleState.pending)
        Chip(
          avatar: Icon(Icons.schedule, size: 16, color: scheme.primary),
          label: Text(t.c1Requested),
        ),
      if (state == C1CircleState.incoming)
        FilledButton.icon(
          onPressed: busy ? null : onAccept,
          icon: const Icon(Icons.check, size: 18),
          label: Text(t.c1Accept),
        ),
      if (state == C1CircleState.accepted) ...[
        FilledButton.tonalIcon(
          key: Key('c1-msg-${user['id']}'),
          onPressed: onMessage,
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: Text(t.c1Message),
        ),
        OutlinedButton.icon(
          onPressed: onCall,
          icon: const Icon(Icons.call_outlined, size: 18),
          label: Text(t.c1Call),
        ),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MsgrAvatar(
            name: shown,
            photoUrl: '${user['photo_link'] ?? user['photo'] ?? ''}',
            radius: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(shown.isEmpty ? '?' : shown,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 16)),
            for (final s in sub)
              Text(s,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: actions),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Not-on-Assisto phonebook row: Invite.
// ---------------------------------------------------------------------------
class C1InviteRow extends StatelessWidget {
  const C1InviteRow({
    super.key,
    required this.name,
    required this.number,
    required this.onInvite,
  });

  final String name;
  final String number;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      leading: MsgrAvatar(name: name.isEmpty ? number : name, radius: 20),
      title: Text(name.isEmpty ? number : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: name.isEmpty
          ? null
          : Text(number, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: TextButton(
        onPressed: onInvite,
        child: Text(t.c1Invite),
      ),
    );
  }
}
