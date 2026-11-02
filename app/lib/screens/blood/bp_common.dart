import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
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
        decoration: BoxDecoration(color: s.errorContainer, shape: BoxShape.circle),
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
          size: 18, color: eligible ? Brand.successFill : s.onSurfaceVariant),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(
          eligible ? t.bpCanNow : t.bpAgainOn(bpDate(context, nextDate)),
          style: TextStyle(color: eligible ? null : s.onSurfaceVariant),
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
        color = Brand.successFill;
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
            style: TextStyle(color: color == null ? s.onSurfaceVariant : null,
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
            style: TextStyle(color: s.primary, fontWeight: FontWeight.w600)),
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
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(icon, size: 40, color: s.error),
          const SizedBox(height: Gap.sm),
          Text(title, style: text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(bpD(context, '${i + 1}.'), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(steps[i])),
              ]),
            ),
          const SizedBox(height: Gap.md),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton(key: ctaKey, onPressed: onCta, child: Text(cta)),
          ),
        ]),
      ),
    );
  }
}

/// The honest privacy card (what others see / what stays private).
class BpPrivacyCard extends StatelessWidget {
  const BpPrivacyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: s.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.lock_outline_rounded, color: s.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.bpPrivacyTitle, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.bpPrivacyBody),
        ]),
      ),
    );
  }
}
