import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'circle_relation.dart';

/// The result of the invite composer: the chosen relationship (mandatory) + an
/// optional family sub-type (never required) + how the invite is delivered.
class CircleInviteChoice {
  final String relation; // mandatory machine code
  final String custom; // free text when relation == custom
  final String? familySub; // optional: father|mother|child|sibling|other
  final String channel; // phone | qr | link
  final String phone; // when channel == phone
  final String note; // ONE optional pre-acceptance text note
  const CircleInviteChoice({
    required this.relation,
    required this.channel,
    this.custom = '',
    this.familySub,
    this.phone = '',
    this.note = '',
  });
}

/// Optional family sub-type codes (NEVER required — the spec forbids proof or a
/// forced choice). Shown only when the chosen relation is a close-family one.
const List<String> kFamilySubTypes = ['father', 'mother', 'child', 'sibling', 'other'];

const Set<String> _closeFamily = {
  'father', 'mother', 'child', 'husband', 'wife', 'brother', 'sister', 'relative'
};

/// The invite composer. Relationship is MANDATORY (send stays disabled until a
/// relation is picked); family sub-type is optional and only offered for family
/// relations. Delivery: send request by phone, show a QR, or copy a share link.
Future<CircleInviteChoice?> showCircleInviteSheet(BuildContext context) {
  return showModalBottomSheet<CircleInviteChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _InviteComposer(),
  );
}

class _InviteComposer extends StatefulWidget {
  const _InviteComposer();
  @override
  State<_InviteComposer> createState() => _InviteComposerState();
}

class _InviteComposerState extends State<_InviteComposer> {
  String? _relation;
  String _custom = '';
  String? _familySub;
  final _phone = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _ready => _relation != null && (_relation != 'custom' || _custom.trim().isNotEmpty);

  void _emit(String channel) {
    if (!_ready) return;
    Navigator.pop(
      context,
      CircleInviteChoice(
        relation: _relation!,
        custom: _custom,
        familySub: _familySub,
        channel: channel,
        phone: _phone.text.trim(),
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final showFamilySub = _relation != null && _closeFamily.contains(_relation);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.circleAddTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            // MANDATORY relationship.
            Row(
              children: [
                Text(t.circleRelationQuestion, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: Gap.xs),
                Text('*', style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: Gap.sm),
            CircleRelationPicker(
              selected: _relation,
              onSelected: (c) => setState(() {
                _relation = c;
                if (!_closeFamily.contains(c)) _familySub = null;
              }),
            ),
            if (_relation == 'custom') ...[
              const SizedBox(height: Gap.sm),
              TextField(
                decoration: InputDecoration(hintText: t.circleCustomRelationHint),
                onChanged: (v) => setState(() => _custom = v),
              ),
            ],
            // OPTIONAL family sub-type (never required).
            if (showFamilySub) ...[
              const SizedBox(height: Gap.md),
              Text(t.circleFamilySubOptional,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                children: [
                  for (final s in kFamilySubTypes)
                    ChoiceChip(
                      label: Text(_familySubLabel(t, s)),
                      selected: _familySub == s,
                      onSelected: (sel) => setState(() => _familySub = sel ? s : null),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: t.circlePhoneLabel,
                prefixIcon: const Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: Gap.md),
            // ONE optional pre-acceptance note — shown to the recipient on the
            // request card. Never required.
            TextField(
              controller: _note,
              maxLength: 200,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                labelText: t.circleRequestNoteLabel,
                hintText: t.circleRequestNoteHint,
                prefixIcon: const Icon(Icons.edit_note_outlined),
              ),
            ),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              icon: const Icon(Icons.send_outlined),
              label: Text(t.circleSendRequest),
              onPressed: _ready && _phone.text.trim().isNotEmpty ? () => _emit('phone') : null,
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_2_outlined),
                    label: Text(t.circleQrInvite),
                    onPressed: _ready ? () => _emit('qr') : null,
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share_outlined),
                    label: Text(t.circleShareLink),
                    onPressed: _ready ? () => _emit('link') : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Text(t.circleNoContactUpload,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  String _familySubLabel(AppLocalizations t, String code) {
    switch (code) {
      case 'father':
        return t.circleRelFather;
      case 'mother':
        return t.circleRelMother;
      case 'child':
        return t.circleRelChild;
      case 'sibling':
        return t.circleFamilySubSibling;
      default:
        return t.circleRelCustom;
    }
  }
}

/// A dialog showing an invite's QR/link + token with copy/share. Drawn with a
/// simple QR placeholder box (the integrator swaps in a real QR widget) plus the
/// selectable deep link so it works before that lands.
Future<void> showCircleInviteLink(
  BuildContext context, {
  required String? link,
  required String? token,
}) {
  final t = AppLocalizations.of(context);
  final value = link ?? token;
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.circleQrInvite),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: const Icon(Icons.qr_code_2, size: 120),
          ),
          const SizedBox(height: Gap.md),
          SelectableText(value ?? t.circleInviteUnavailable, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        if (value != null)
          TextButton.icon(
            icon: const Icon(Icons.copy_outlined),
            label: Text(t.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Navigator.pop(ctx);
            },
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
      ],
    ),
  );
}
