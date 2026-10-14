import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'contacts_model.dart';

/// Detail + editor bottom sheets for the personal-CRM contact.
/// Returns are driven back to the screen (save / delete / log-contact), which
/// owns the API + offline cache. These widgets are presentation only.

// ---------------------------------------------------------------------------
// Quick actions (call / sms / whatsapp-share / email) — never a dead button
// ---------------------------------------------------------------------------
Future<void> _launch(BuildContext c, Uri uri) async {
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {/* no dead end: silently ignore an unavailable handler */}
}

String _onlyPhone(String s) {
  final out = StringBuffer();
  final hasPlus = s.trim().startsWith('+');
  if (hasPlus) out.write('+');
  for (final ch in s.split('')) {
    if ('0123456789'.contains(ch)) out.write(ch);
  }
  return out.toString();
}

class ContactQuickActions extends StatelessWidget {
  final Contact contact;
  const ContactQuickActions({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = contact.bestPhone();
    final email = contact.bestEmail();
    final buttons = <Widget>[];

    Widget act(IconData icon, String label, Color color, VoidCallback onTap) =>
        Expanded(
          child: Semantics(
            button: true,
            label: label,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Column(children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: color.withValues(alpha: 0.14),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(height: 4),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        );

    if (phone != null) {
      buttons.add(act(Icons.call, cStr(context, 'cCall'), Brand.success,
          () => _launch(context, Uri.parse('tel:${phone.trim()}'))));
      buttons.add(act(Icons.sms_outlined, cStr(context, 'cSms'), scheme.primary,
          () => _launch(context, Uri.parse('sms:${phone.trim()}'))));
      buttons.add(act(Icons.chat_outlined, cStr(context, 'cWhatsapp'),
          const Color(0xFF25D366), () {
        final wa = 'https://wa.me/${_onlyPhone(phone)}';
        _launch(context, Uri.parse(wa));
      }));
    }
    if (email != null) {
      buttons.add(act(Icons.email_outlined, cStr(context, 'cEmailAction'),
          scheme.tertiary, () => _launch(context, Uri.parse('mailto:$email'))));
    }
    // share vCard always available (never a dead end even with no phone/email)
    buttons.add(act(Icons.ios_share, cStr(context, 'cShareVcard'),
        scheme.secondary, () => Share.share(contact.toVcard(context))));

    return Row(children: buttons);
  }
}

// ---------------------------------------------------------------------------
// Detail sheet
// ---------------------------------------------------------------------------
enum ContactDetailResult { none, edit, delete, logged, linkCircle }

Future<ContactDetailResult> showContactDetail(
    BuildContext context, Contact c,
    {required Future<void> Function() onLogContact}) async {
  final res = await showModalBottomSheet<ContactDetailResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ContactDetailSheet(contact: c, onLogContact: onLogContact),
  );
  return res ?? ContactDetailResult.none;
}

class _ContactDetailSheet extends StatelessWidget {
  final Contact contact;
  final Future<void> Function() onLogContact;
  const _ContactDetailSheet(
      {required this.contact, required this.onLogContact});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = contact;
    final rows = <Widget>[];

    Widget field(IconData icon, String value, {VoidCallback? onTap, String? copy}) =>
        ListTile(
          leading: Icon(icon, color: scheme.primary),
          title: Text(value),
          trailing: copy == null
              ? null
              : IconButton(
                  tooltip: tr.copy,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: copy));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr.copied)));
                  }),
          onTap: onTap,
        );

    for (final p in c.phones) {
      rows.add(field(Icons.phone, p,
          onTap: () => _launch(context, Uri.parse('tel:${p.trim()}')),
          copy: p));
    }
    for (final e in c.emails) {
      rows.add(field(Icons.email_outlined, e,
          onTap: () => _launch(context, Uri.parse('mailto:$e')), copy: e));
    }
    for (final a in c.addresses) {
      rows.add(field(Icons.location_on_outlined, a, copy: a));
    }
    if (c.org.isNotEmpty) rows.add(field(Icons.business, c.org));
    if (c.birthday.isNotEmpty) {
      rows.add(field(Icons.cake_outlined, c.birthday));
    }
    if (c.note.isNotEmpty) rows.add(field(Icons.notes, c.note));

    final since = c.daysSinceInteraction();
    final touchLine = c.cadence.isEmpty
        ? null
        : c.touchDue()
            ? cStr(context, 'cDueToReach')
            : since == null
                ? cStr(context, 'cNeverTalked')
                : cStrNum(context, 'cLastTalkedDays', since);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // header
          Row(children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: scheme.primaryContainer,
              child: Text(c.initial(context),
                  style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(c.displayName(context),
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (c.favourite) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star, color: Brand.warning, size: 20),
                  ],
                ]),
                if (c.relation.isNotEmpty || c.linkedUserId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(spacing: 6, children: [
                      if (c.relation.isNotEmpty)
                        ContactTag(
                            text: relationDisplay(context, c.relation),
                            icon: Icons.favorite_border),
                      if (c.linkedUserId != null)
                        ContactTag(
                            text: cStr(context, 'cLinkedCircle'),
                            icon: Icons.link,
                            color: scheme.tertiary),
                    ]),
                  ),
              ]),
            ),
            IconButton(
                tooltip: cStr(context, 'cEditContact'),
                icon: const Icon(Icons.edit_outlined),
                onPressed: () =>
                    Navigator.pop(context, ContactDetailResult.edit)),
          ]),
          const SizedBox(height: Gap.md),
          ContactQuickActions(contact: c),
          if (c.groups.isNotEmpty || c.labels.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final g in c.groups)
                ContactTag(
                    text: groupLabel(context, g), icon: groupIcon(g)),
              for (final l in c.labels) ContactTag(text: l),
            ]),
          ],
          if (touchLine != null) ...[
            const SizedBox(height: Gap.md),
            Card(
              color: c.touchDue()
                  ? Brand.warning.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(Icons.favorite,
                    color: c.touchDue() ? Brand.warning : scheme.primary),
                title: Text(touchLine),
                subtitle: Text(
                    '${cStr(context, 'cStayInTouch')}: ${cadenceLabel(context, c.cadence)}'),
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    await onLogContact();
                    if (context.mounted) {
                      Navigator.pop(context, ContactDetailResult.logged);
                    }
                  },
                  child: Text(cStr(context, 'cLogContact')),
                ),
              ),
            ),
          ],
          const SizedBox(height: Gap.sm),
          ...rows,
          const Divider(),
          Row(children: [
            if (c.linkedUserId == null)
              TextButton.icon(
                icon: const Icon(Icons.link),
                label: Text(cStr(context, 'cLinkCircle')),
                onPressed: () =>
                    Navigator.pop(context, ContactDetailResult.linkCircle),
              ),
            const Spacer(),
            TextButton.icon(
              icon: Icon(Icons.delete_outline, color: scheme.error),
              label: Text(tr.delete, style: TextStyle(color: scheme.error)),
              onPressed: () =>
                  Navigator.pop(context, ContactDetailResult.delete),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editor sheet (add / edit) — multi phone/email/address, groups, relation,
// birthday, cadence, favourite, labels, notes.
// ---------------------------------------------------------------------------
Future<Contact?> showContactEditor(BuildContext context, {Contact? existing}) {
  return showModalBottomSheet<Contact>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _ContactEditor(existing: existing),
    ),
  );
}

class _ContactEditor extends StatefulWidget {
  final Contact? existing;
  const _ContactEditor({this.existing});
  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  late final TextEditingController _name;
  late final TextEditingController _org;
  late final TextEditingController _note;
  late final List<TextEditingController> _phones;
  late final List<TextEditingController> _emails;
  late final List<TextEditingController> _addresses;
  late final TextEditingController _label;
  late List<String> _labels;
  late Set<String> _groups;
  late String _relation;
  late String _cadence;
  late bool _favourite;
  String _birthday = '';

  @override
  void initState() {
    super.initState();
    final c = widget.existing ?? Contact();
    _name = TextEditingController(text: c.name);
    _org = TextEditingController(text: c.org);
    _note = TextEditingController(text: c.note);
    _phones = _ctrls(c.phones);
    _emails = _ctrls(c.emails);
    _addresses = _ctrls(c.addresses);
    _label = TextEditingController();
    _labels = List.of(c.labels);
    _groups = Set.of(c.groups);
    _relation = c.relation;
    _cadence = c.cadence;
    _favourite = c.favourite;
    _birthday = c.birthday;
  }

  List<TextEditingController> _ctrls(List<String> vals) {
    if (vals.isEmpty) return [TextEditingController()];
    return vals.map((v) => TextEditingController(text: v)).toList();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _org,
      _note,
      _label,
      ..._phones,
      ..._emails,
      ..._addresses
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _collect(List<TextEditingController> cs) {
    final out = <String>[];
    final seen = <String>{};
    for (final c in cs) {
      final v = c.text.trim();
      if (v.isNotEmpty && seen.add(v.toLowerCase())) out.add(v);
    }
    return out;
  }

  void _save() {
    final c = widget.existing ?? Contact();
    c.name = _name.text.trim();
    c.org = _org.text.trim();
    c.note = _note.text.trim();
    c.phones = _collect(_phones);
    c.emails = _collect(_emails);
    c.addresses = _collect(_addresses);
    c.labels = _labels;
    c.groups = _groups.toList();
    c.relation = _relation;
    c.cadence = _cadence;
    c.favourite = _favourite;
    c.birthday = _birthday;
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canSave = _name.text.trim().isNotEmpty ||
        _collect(_phones).isNotEmpty ||
        _collect(_emails).isNotEmpty;

    Widget multiField(
      String addLabel,
      IconData icon,
      List<TextEditingController> cs,
      TextInputType kb,
    ) {
      return Column(children: [
        for (var i = 0; i < cs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: cs[i],
                  keyboardType: kb,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: Icon(icon),
                    labelText: addLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              if (cs.length > 1)
                IconButton(
                  icon: Icon(Icons.remove_circle_outline, color: scheme.error),
                  onPressed: () => setState(() => cs.removeAt(i)),
                ),
            ]),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
            onPressed: () =>
                setState(() => cs.add(TextEditingController())),
          ),
        ),
      ]);
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              widget.existing == null
                  ? tr.addContact
                  : cStr(context, 'cEditContact'),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.person_outline),
              labelText: tr.name,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.star,
                color: _favourite ? Brand.warning : scheme.outline),
            title: Text(cStr(context, 'cFavourite')),
            value: _favourite,
            onChanged: (v) => setState(() => _favourite = v),
          ),
          const Divider(),
          _sectionLabel(context, cStr(context, 'cPhones')),
          multiField(cStr(context, 'cAddPhone'), Icons.phone, _phones,
              TextInputType.phone),
          const SizedBox(height: Gap.sm),
          _sectionLabel(context, cStr(context, 'cEmails')),
          multiField(cStr(context, 'cAddEmail'), Icons.email_outlined, _emails,
              TextInputType.emailAddress),
          const SizedBox(height: Gap.sm),
          _sectionLabel(context, cStr(context, 'cAddresses')),
          multiField(cStr(context, 'cAddAddress'), Icons.location_on_outlined,
              _addresses, TextInputType.streetAddress),
          const Divider(),
          TextField(
            controller: _org,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.business),
              labelText: tr.organization,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          // relationship picker
          _sectionLabel(context, cStr(context, 'cRelationship')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final r in relationOrder)
              ChoiceChip(
                label: Text(relationDisplay(context, r)),
                selected: _relation == r,
                onSelected: (s) =>
                    setState(() => _relation = s ? r : ''),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // groups
          _sectionLabel(context, cStr(context, 'cGroups')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final g in kGroupOrder)
              FilterChip(
                avatar: Icon(groupIcon(g), size: 16),
                label: Text(groupLabel(context, g)),
                selected: _groups.contains(g),
                onSelected: (s) => setState(
                    () => s ? _groups.add(g) : _groups.remove(g)),
              ),
          ]),
          const SizedBox(height: Gap.md),
          // labels
          _sectionLabel(context, cStr(context, 'cLabels')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in _labels)
              InputChip(
                label: Text(l),
                onDeleted: () => setState(() => _labels.remove(l)),
              ),
          ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _label,
                decoration: InputDecoration(
                  hintText: cStr(context, 'cLabelHint'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _addLabel(),
              ),
            ),
            IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _addLabel),
          ]),
          const SizedBox(height: Gap.md),
          // birthday
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cake_outlined),
            title: Text(cStr(context, 'cBirthday')),
            subtitle:
                _birthday.isEmpty ? null : Text(_birthday),
            trailing: TextButton(
              onPressed: _pickBirthday,
              child: Text(_birthday.isEmpty ? tr.add : tr.edit),
            ),
          ),
          // stay-in-touch cadence
          _sectionLabel(context, cStr(context, 'cStayInTouch')),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final cad in kCadenceOrder)
              ChoiceChip(
                label: Text(cadenceLabel(context, cad)),
                selected: _cadence == cad,
                onSelected: (s) => setState(() => _cadence = s ? cad : ''),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            maxLines: 3,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.notes),
              labelText: tr.note,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  void _addLabel() {
    final v = _label.text.trim();
    if (v.isEmpty) return;
    setState(() {
      if (!_labels.any((x) => x.toLowerCase() == v.toLowerCase())) {
        _labels.add(v);
      }
      _label.clear();
    });
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _birthday =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
    }
  }
}

Widget _sectionLabel(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary)),
    );
