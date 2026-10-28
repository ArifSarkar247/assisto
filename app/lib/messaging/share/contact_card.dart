import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../c1_contacts_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../services/phone_canon.dart';
import '../../theme.dart';
import '../date_separators.dart' show localDigits;
import '../msg_request_widgets.dart' show openMessageRequestChat;
import 'share_payload.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// mc-media2 — what the contact card's buttons do. Every action is a seam so
/// the widget tests run without a phone, a network or the contacts app.
class ContactCardActions {
  ContactCardActions._();

  /// Is this number on Assisto? (POST /messenger/contacts/lookup; cached per
  /// app run so a scrolled chat never asks twice.)
  static Future<bool> Function(BuildContext context, String phone) isOnAssisto = _lookup;

  /// Open the 1:1 chat (a message request when not connected yet).
  static Future<void> Function(BuildContext context, ContactShare c) message =
      (context, c) async {
    await openMessageRequestChat(context,
        toUserId: c.uid, phone: c.uid == null ? PhoneCanon.canonical(c.phones.first) : null);
  };

  /// The phone's own "new contact" screen, pre-filled (ACTION_INSERT; no
  /// contacts permission needed).
  static Future<bool> Function(ContactShare c) addToContacts = (c) async {
    try {
      final contact = fc.Contact()
        ..name = fc.Name(first: c.name)
        ..displayName = c.name
        ..phones = [for (final p in c.phones) fc.Phone(p)];
      unawaited(fc.FlutterContacts.openExternalInsert(contact).then((_) {}, onError: (_) {}));
      return true;
    } catch (_) {
      return false;
    }
  };

  /// The phone's dialer with the number (the user presses call).
  static Future<bool> Function(String phone) call = (phone) async {
    try {
      return await launchUrl(Uri(scheme: 'tel', path: phone),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  };

  static final Map<String, Future<bool>> _cache = {};

  static Future<bool> _lookup(BuildContext context, String phone) {
    final canon = PhoneCanon.canonical(phone);
    if (canon == null) return Future.value(false);
    final api = context.read<AppState>().api;
    return _cache.putIfAbsent(canon, () async {
      try {
        final r = await api.contactsLookup(canon);
        return r['found'] == true;
      } catch (_) {
        _cache.remove(canon); // offline: ask again next time
        return false;
      }
    });
  }
}

class ContactCard extends StatefulWidget {
  final ContactShare contact;
  final bool mine;
  final Color fg;
  const ContactCard({super.key, required this.contact, required this.mine, required this.fg});

  @override
  State<ContactCard> createState() => _ContactCardState();
}

class _ContactCardState extends State<ContactCard> {
  bool _onAssisto = false;

  @override
  void initState() {
    super.initState();
    final c = widget.contact;
    if (c.uid != null) {
      _onAssisto = true;
    } else if (!widget.mine && c.phones.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  Future<void> _check() async {
    if (!mounted) return;
    final ok = await ContactCardActions.isOnAssisto(context, widget.contact.phones.first);
    if (mounted && ok) setState(() => _onAssisto = true);
  }

  Future<void> _call() async {
    final phones = widget.contact.phones;
    var phone = phones.first;
    if (phones.length > 1) {
      final lang = Localizations.localeOf(context).languageCode;
      final pick = await showAppSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final p in phones)
              ListTile(
                leading: const Icon(Icons.call_rounded),
                title: Text(localDigits(p, lang)),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ]),
        ),
      );
      if (pick == null) return;
      phone = pick;
    }
    final ok = await ContactCardActions.call(phone);
    if (!ok && mounted) _snack(AppLocalizations.of(context).mc2ActionFailed);
  }

  void _snack(String m) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final scheme = Theme.of(context).colorScheme;
    final c = widget.contact;
    final name = c.name.isEmpty ? t.circleAttachContact : c.name;
    final muted = widget.fg.withValues(alpha: 0.78);
    final btnColor = widget.mine ? widget.fg : scheme.primary;
    ButtonStyle style() => TextButton.styleFrom(
        foregroundColor: btnColor,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        minimumSize: const Size(48, 40));
    return SizedBox(
      width: 248,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: scheme.secondaryContainer,
              child: Text(name.characters.first.toUpperCase(),
                  style: TextStyle(
                      color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name,
                    key: const Key('mc2-contact-name'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.fg, fontWeight: FontWeight.w600, fontSize: 14)),
                for (final p in c.phones)
                  Text(localDigits(p, lang), style: TextStyle(color: muted, fontSize: 12)),
                if (_onAssisto)
                  Text(t.mc2OnAssisto,
                      key: const Key('mc2-contact-on-assisto'),
                      style: TextStyle(color: muted, fontSize: 12)),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.xs, children: [
            if (_onAssisto && !widget.mine)
              TextButton.icon(
                key: const Key('mc2-contact-message'),
                style: style(),
                onPressed: () => ContactCardActions.message(context, c),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: Text(t.mc2MessageOnAssisto),
              ),
            if (c.phones.isNotEmpty && !widget.mine)
              TextButton.icon(
                key: const Key('mc2-contact-add'),
                style: style(),
                onPressed: () async {
                  final ok = await ContactCardActions.addToContacts(c);
                  if (!ok && mounted) _snack(t.mc2ActionFailed);
                },
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: Text(t.mc2AddToContacts),
              ),
            if (c.phones.isNotEmpty)
              TextButton.icon(
                key: const Key('mc2-contact-call'),
                style: style(),
                onPressed: _call,
                icon: const Icon(Icons.call_rounded, size: 18),
                label: Text(t.mc2Call),
              ),
          ]),
        ],
      ),
    );
  }
}
