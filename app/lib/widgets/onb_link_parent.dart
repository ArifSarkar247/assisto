import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../services/action_feedback.dart'; // db1

/// Link a parent (or any loved one) in under 2 minutes.
///
/// Mirrors backend `core/logic/parent_link.py` on-device so the step works with
/// no round-trip: enter a phone, pick the relation, then invite by the honest
/// channels. Call / SMS (own-SIM) / QR work NOW; IVR for feature phones is
/// 🔑 key-gated and shown as a clear "Available when ___" locked row — never a
/// dead tap. All strings localized; zero Bangla in this file.
///
/// `ivrEnabled` reflects whether the owner has connected an IVR provider; the
/// integrator passes the real value (see up_onb_integration note). Defaults
/// false so the honest locked state is the default.
class OnbLinkParent extends StatefulWidget {
  final VoidCallback onOpenFamily;
  final VoidCallback onSkip;
  final bool ivrEnabled;
  const OnbLinkParent({
    super.key,
    required this.onOpenFamily,
    required this.onSkip,
    this.ivrEnabled = false,
  });

  @override
  State<OnbLinkParent> createState() => _OnbLinkParentState();
}

class _OnbLinkParentState extends State<OnbLinkParent> {
  final _phone = TextEditingController();
  String _relation = 'parent'; // parent | father | mother | child | other
  String? _error; // set on invalid phone
  bool _preparing = false; // brief "preparing invite" loading state

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  // --- mirror of parent_link.normalize_phone / validate_phone ---
  String get _number {
    final raw = _phone.text.trim();
    final plus = raw.startsWith('+');
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return plus ? '+$digits' : digits;
  }

  int get _digitCount => _number.replaceAll('+', '').length;
  bool get _hasPhone => _digitCount > 0;

  /// Returns a localized error string, or null if valid.
  String? _validate(AppLocalizations t) {
    if (!_hasPhone) return t.onbErrorPhoneRequired;
    if (_digitCount < 6) return t.onbErrorPhoneInvalid;
    return null;
  }

  String _invite(AppLocalizations t) => t.onbInviteMessage;

  /// Runs the shared validate → brief prepare → action pipeline so every
  /// channel surfaces the same error/loading behaviour.
  Future<void> _withInvite(
      AppLocalizations t, Future<void> Function() action) async {
    final err = _validate(t);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _preparing = true;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _tel(AppLocalizations t) => _withInvite(t, () async {
        await openForUser(context, Uri.parse('tel:$_number'), where: 'onb.call'); // db1
      });

  Future<void> _sms(AppLocalizations t) => _withInvite(t, () async {
        // Own-SIM composer, prefilled — user presses Send. No SEND_SMS perm,
        // no gateway (matches parent_link.invite_non_user_sms).
        final uri = Uri.parse(
            'sms:$_number?body=${Uri.encodeComponent(_invite(t))}');
        await openForUser(context, uri, where: 'onb.sms'); // db1
      });

  Future<void> _copyLink(AppLocalizations t) => _withInvite(t, () async {
        await Clipboard.setData(ClipboardData(text: _invite(t)));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.onbInviteLinkCopied)));
        }
      });

  Future<void> _showQr(AppLocalizations t) => _withInvite(t, () async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) {
            final scheme = Theme.of(ctx).colorScheme;
            return AlertDialog(
              title: Text(t.onbInviteQrTitle),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                // Honest QR affordance: the deep link is real and copyable now;
                // the scannable image renders once the QR encoder lands (same
                // pattern as circle_invite_sheet). The link below always works.
                Container(
                  padding: const EdgeInsets.all(Gap.lg),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(Icons.qr_code_2,
                      size: 120, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Gap.md),
                Text(t.onbInviteQrBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ]),
              actions: [
                TextButton.icon(
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(t.onbInviteCopy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _invite(t)));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.onbInviteLinkCopied)));
                  },
                ),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(t.continueWord)),
              ],
            );
          },
        );
      });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    final relations = <(String, String)>[
      ('parent', t.onbLinkRelationParent),
      ('father', t.onbLinkRelationFather),
      ('mother', t.onbLinkRelationMother),
      ('child', t.onbLinkRelationChild),
      ('other', t.onbLinkRelationOther),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Icon(Icons.favorite, size: 40, color: scheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.onbLinkParentTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.onbLinkParentSub,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),

        // Phone field — the error state lives on the field.
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          onChanged: (_) => setState(() => _error = null),
          decoration: InputDecoration(
            labelText: t.onbParentPhoneLabel,
            hintText: t.onbLinkParentPhoneHint,
            prefixIcon: const Icon(Icons.phone_outlined),
            errorText: _error,
          ),
        ),
        const SizedBox(height: Gap.lg),

        // Relation chips (who they are to me).
        Text(t.onbLinkRelationLabel,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.sm),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            for (final r in relations)
              ChoiceChip(
                label: Text(r.$2),
                selected: _relation == r.$1,
                onSelected: (_) => setState(() => _relation = r.$1),
              ),
          ],
        ),
        const SizedBox(height: Gap.lg),

        Text(t.onbLinkWaysTitle,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: Gap.sm),

        // Loading state: a slim bar while an invite is being prepared/opened.
        if (_preparing)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: Gap.sm),
              Text(t.onbPreparingInvite,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ]),
          ),

        // Three working channels.
        Row(children: [
          Expanded(
            child: _inviteBtn(
                scheme, Icons.call_outlined, t.onbInviteCall, () => _tel(t)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _inviteBtn(
                scheme, Icons.sms_outlined, t.onbInviteSms, () => _sms(t)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _inviteBtn(scheme, Icons.qr_code_2_outlined,
                t.onbInviteShowQr, () => _showQr(t)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        // Copy-link fallback (always works, even with no phone? — still gated
        // behind validate so the link targets a real invite).
        TextButton.icon(
          onPressed: () => _copyLink(t),
          icon: const Icon(Icons.link_outlined, size: 18),
          label: Text(t.onbInviteCopy),
        ),
        const SizedBox(height: Gap.md),

        // IVR — honest key-gated row for FEATURE phones.
        _ivrRow(scheme, t),
        const SizedBox(height: Gap.xl),

        FilledButton.icon(
          onPressed: widget.onOpenFamily,
          icon: const Icon(Icons.diversity_1_outlined),
          style:
              FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          label: Text(t.onbManageFamily),
        ),
        const SizedBox(height: Gap.xs),
        TextButton(onPressed: widget.onSkip, child: Text(t.onbSkipForNow)),
      ],
    );
  }

  Widget _inviteBtn(
      ColorScheme scheme, IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: _preparing ? null : onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        minimumSize: const Size.fromHeight(64),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20),
        const SizedBox(height: 4),
        Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  /// IVR row: a live action if the owner connected a provider, else an honest
  /// locked "Available when ___" affordance (never a dead tap).
  Widget _ivrRow(ColorScheme scheme, AppLocalizations t) {
    final enabled = widget.ivrEnabled;
    return Opacity(
      opacity: enabled ? 1 : 0.72,
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(children: [
          Icon(Icons.phone_in_talk_outlined,
              size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.onbInviteIvr,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(enabled ? t.onbInviteIvrHint : t.onbAvailableWhenIvr,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: scheme.onSurfaceVariant)),
                ]),
          ),
          Icon(enabled ? Icons.chevron_right : Icons.lock_clock_outlined,
              size: 18, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}
