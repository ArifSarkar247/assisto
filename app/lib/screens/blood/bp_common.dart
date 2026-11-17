import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../blood_panel_api.dart' show kBloodGroups;
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../../widgets/permission_reason.dart' show askLocationWithReason;

/// blood (owner 2 Nov): shared bits of the Blood donor panel screens.

String bpD(BuildContext context, String s) => notifLocalizeDigits(context, s);

/// Server reason code -> one honest sentence.
String bpReason(AppLocalizations t, String? reason) {
  switch (reason) {
    case 'feature_off':
      return t.bpErrOff;
    case 'invalid':
      return t.bpErrFields;
    case 'consent_required':
      return t.bpErrConsent;
    case 'area_required':
      return t.bpErrArea;
    case 'rate_limited':
      return t.bpErrRate;
    case 'too_many_requests':
      return t.bpErrTooManyReq;
    case 'too_many_active':
      return t.bpErrTooManyActive;
    case 'banned':
      return t.bpErrBanned;
    case 'not_eligible':
      return t.bpErrNotEligible;
    case 'incompatible':
      return t.bpErrIncompatible;
    case 'not_donor':
      return t.bpErrNotDonor;
    case 'not_active':
      return t.bpErrNotActive;
    case 'blocked':
      return t.bpErrBlocked;
    case 'not_available':
      return t.bpErrNotAvailable;
    case 'already':
      return t.bpErrAlready;
    case 'already_pending':
      return t.bpVerifyPending;
    case 'bad_photo':
      return t.bpErrPhoto;
    default:
      return t.bpErrGeneric;
  }
}

/// Local date, digits localised ('2026-11-02' -> "2 Nov 2026" / Bangla).
String bpDate(BuildContext context, String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return '';
  return bpD(context, MaterialLocalizations.of(context).formatMediumDate(d));
}

/// Local date + time, digits localised.
String bpWhen(BuildContext context, String? iso) {
  final at = DateTime.tryParse(iso ?? '')?.toLocal();
  if (at == null) return '';
  final loc = MaterialLocalizations.of(context);
  return bpD(context,
      '${loc.formatMediumDate(at)}, ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(at))}');
}

String bpStateLabel(AppLocalizations t, String state) {
  switch (state) {
    case 'active':
      return t.bpStateActive;
    case 'hidden':
      return t.bpStateHidden;
    case 'fulfilled':
      return t.bpStateFound;
    case 'expired':
      return t.bpStateExpired;
    case 'closed':
      return t.bpStateClosed;
    default:
      return t.bpStateRemoved;
  }
}

// gap-quranblood B2: share an open request to WhatsApp / Facebook /
// Messenger (where most Bangladeshi blood requests travel). The text carries
// the group, bags, hospital, area and time only — NEVER a phone number, the
// note (it can hold medical details) or the requester's name.
const String kBpSiteLink = 'https://lifeassisto.com';

String bpRequestShareText(BuildContext context, Map<String, dynamic> r) {
  final t = AppLocalizations.of(context);
  final place = [
    if ('${r['area_text'] ?? ''}'.isNotEmpty) '${r['area_text']}',
    if ('${r['district_name'] ?? ''}'.isNotEmpty) '${r['district_name']}',
  ].join(', ');
  return bpD(
      context,
      t.bpShareReqText('${r['blood_group'] ?? ''}', '${r['units'] ?? 1}',
          '${r['hospital'] ?? ''}', place.isEmpty ? '—' : place,
          bpWhen(context, r['needed_by'] as String?), kBpSiteLink));
}

/// Test seam: the system share sheet.
Future<void> Function(String text) bpShareOut = (text) => Share.share(text);

/// gap-quranblood B4: making the number public needs a clear yes — who sees
/// it is said plainly. Turning it OFF never asks.
Future<bool?> bpConfirmPhonePublic(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showAppSheet<bool>(
    context: context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.bpPhonePublicConfirmTitle, style: Theme.of(ctx).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Text(t.bpPhonePublicConfirmBody, key: const ValueKey('bp-phone-confirm-body')),
        const SizedBox(height: Gap.lg),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
          child: FilledButton(
            key: const ValueKey('bp-phone-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.bpPhonePublicConfirmOk),
          ),
        ),
        TextButton(
          key: const ValueKey('bp-phone-keep-private'),
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t.bpPhoneKeepPrivate),
        ),
      ]),
    ),
  );
}

/// The phone's current position, or null (no permission / off / timeout).
/// Never in the background; the caller rounds it to ~1 km before sending.
/// Android's prompt only after the in-app reason (askLocationWithReason).
Future<({double lat, double lng})?> bpLocate(BuildContext context) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    if (!context.mounted) return null;
    final perm = await askLocationWithReason(context);
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return null;
    }
    final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
    return (lat: p.latitude, lng: p.longitude);
  } catch (_) {
    return null;
  }
}

/// Opens the user's OWN dialer / SMS app (only for a number the donor made
/// public). Never auto-dials.
Future<void> bpLaunch(BuildContext context, String scheme, String number) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ok = await launchUrl(Uri(scheme: scheme, path: number));
    if (!ok) messenger.showSnackBar(SnackBar(content: Text(t.bpLaunchFailed)));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(t.bpLaunchFailed)));
  }
}

/// A round blood-group badge (text, not colour only — TalkBack reads it).
class BpGroupBadge extends StatelessWidget {
  const BpGroupBadge(this.group, {super.key, this.size = 48});
  final String group;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Semantics(
      label: AppLocalizations.of(context).bpGroupLabel(group),
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(Gap.xs),
        decoration: BoxDecoration(
          color: s.errorContainer,
          shape: BoxShape.circle,
          border: Border.all(color: DsTokens.of(context).dangerBorder),
        ),
        // fixed size (ListTile leading needs it); the text scales down at 200%
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(group,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: s.onErrorContainer, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// "Can donate now" / "Available again on <date>" line.
class BpEligibility extends StatelessWidget {
  const BpEligibility({super.key, required this.eligible, this.nextDate});
  final bool eligible;
  final String? nextDate;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(eligible ? Icons.check_circle_rounded : Icons.schedule_rounded,
          size: 18, color: eligible ? DsTokens.of(context).successInk : s.onSurfaceVariant),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(
          eligible ? t.bpCanNow : t.bpAgainOn(bpDate(context, nextDate)),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: eligible ? null : s.onSurfaceVariant),
        ),
      ),
    ]);
  }
}

/// finish1 (owner final 2 Nov): one donor's status in the list — never
/// hidden: "Can donate now" (green), "Donated N days ago · M days left",
/// or "Paused by the donor". The numbers come from today's date on the
/// server, so the list moves forward daily by itself.
class BpDonorStatus extends StatelessWidget {
  const BpDonorStatus({super.key, required this.donor});
  final Map<String, dynamic> donor;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final st = '${donor['status'] ?? (donor['eligible'] == true ? 'available' : 'waiting')}';
    final left = (donor['days_left'] as num?)?.toInt() ?? 0;
    final ago = (donor['donated_days_ago'] as num?)?.toInt();
    final String label;
    final IconData icon;
    Color? color;
    switch (st) {
      case 'available':
        label = t.bpCanNow;
        icon = Icons.check_circle_rounded;
        color = DsTokens.of(context).successInk;
      case 'paused':
        label = t.bpStPaused;
        icon = Icons.pause_circle_outline_rounded;
      default:
        label = ago == null
            ? t.bpStLeft(left)
            : (ago == 0 ? t.bpStToday(left) : t.bpStAgoLeft(ago, left));
        icon = Icons.schedule_rounded;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color ?? s.onSurfaceVariant),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(bpD(context, label),
            key: ValueKey('bp-status-${donor['id']}'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color == null ? s.onSurfaceVariant : null,
                fontWeight: st == 'available' ? FontWeight.w600 : null)),
      ),
    ]);
  }
}

class BpVerifiedChip extends StatelessWidget {
  const BpVerifiedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.verified_rounded, size: 18, color: s.primary),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(AppLocalizations.of(context).bpVerified,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: s.primary, fontWeight: FontWeight.w600)),
      ),
    ]);
  }
}

/// A small error state with a retry button.
class BpError extends StatelessWidget {
  const BpError({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.wifi_off_rounded, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(t.bpLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton(onPressed: onRetry, child: Text(t.bpRetry)),
      ]),
    );
  }
}

/// Empty state = one benefit line + one big button + 3 how-to steps.
class BpEmpty extends StatelessWidget {
  const BpEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.steps,
    required this.cta,
    required this.onCta,
    this.ctaKey,
  });
  final IconData icon;
  final String title;
  final List<String> steps;
  final String cta;
  final VoidCallback onCta;
  final Key? ctaKey;

  @override
  Widget build(BuildContext context) {
    // designv2: illustration + benefit line + big button + how-to steps.
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    return DsCard(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: DsIllustration(icon: icon, color: ds.danger, size: 84)),
        const SizedBox(height: Gap.md),
        Text(title,
            style: text.titleMedium?.copyWith(color: ds.text, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DsStepNumber(i + 1),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(steps[i], style: text.bodyMedium?.copyWith(color: ds.text))),
            ]),
          ),
        const SizedBox(height: Gap.md),
        DsButton(key: ctaKey, onPressed: onCta, label: cta, expand: true),
      ]),
    );
  }
}

/// The honest privacy card (what others see / what stays private).
class BpPrivacyCard extends StatelessWidget {
  const BpPrivacyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    // designv2: a calm, flat note (no shadow) — information, not an action.
    return DsSurface(
      flat: true,
      color: ds.cardAlt,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.lock_outline_rounded, color: ds.primaryInk, size: 20),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.bpPrivacyTitle,
                  style: text.titleSmall?.copyWith(color: ds.text))),
        ]),
        const SizedBox(height: Gap.sm),
        Text(t.bpPrivacyBody, style: text.bodyMedium?.copyWith(color: ds.muted)),
      ]),
    );
  }
}

/// designv2: the blood-group 4 x 2 grid used by the request form and donor
/// setup (same look as the hub). Cells are keyed '<keyPrefix><group>'.
class BpGroupGrid extends StatelessWidget {
  const BpGroupGrid({super.key, required this.selected, required this.onTap, required this.keyPrefix});
  final String selected;
  final ValueChanged<String> onTap;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    final t = AppLocalizations.of(context);
    Widget cell(String g) {
      final on = selected == g;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xs),
          child: Semantics(
            selected: on,
            button: true,
            label: t.bpGroupLabel(g),
            child: DsSurface(
              key: ValueKey('$keyPrefix$g'),
              padding: const EdgeInsets.symmetric(vertical: Gap.md),
              color: on ? ds.dangerFill : null,
              borderColor: on ? ds.dangerFill : null,
              onTap: () => onTap(g),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTap - Gap.md),
                child: Center(
                  child: ExcludeSemantics(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(g,
                          maxLines: 1,
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: on ? ds.onDangerFill : ds.dangerInk,
                          )),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(children: [
      for (var row = 0; row < 2; row++)
        Row(children: [for (final g in kBloodGroups.skip(row * 4).take(4)) cell(g)]),
    ]);
  }
}
