import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// missing (owner 2 Nov): shared bits of the Missing person alert screens.

String maD(BuildContext context, String s) => notifLocalizeDigits(context, s);

/// Server reason code -> one honest sentence.
String maReason(AppLocalizations t, String? reason) {
  switch (reason) {
    case 'feature_off':
      return t.maErrOff;
    case 'invalid':
      return t.maErrFields;
    case 'gd_required':
      return t.maErrGdV2;
    case 'not_family':
      return t.maErrNotFamily;
    case 'too_many_active':
      return t.maErrTooMany;
    case 'too_many_posts':
      return t.maErrTooManyPosts;
    case 'banned':
      return t.maErrBanned;
    case 'cooling':
      return t.maErrCoolingV2;
    case 'already_active':
      return t.maErrAlready;
    case 'rate_limited':
      return t.maErrRate;
    case 'not_active':
      return t.maErrNotActive;
    case 'too_early':
      return t.maErrTooEarly;
    case 'gd_reconfirm':
      return t.maErrGdReconfirmV2;
    case 'max_renewals':
      return t.maErrMaxRenew;
    case 'area_required':
      return t.maErrArea;
    default:
      return t.maErrGeneric;
  }
}

String maStateLabel(AppLocalizations t, String state, {bool safeSaid = false}) {
  switch (state) {
    case 'active':
      return safeSaid ? t.maStateChildSafe : t.maStateActive;
    case 'pending':
      return t.maStatePending;
    case 'hidden':
      return t.maStateHidden;
    case 'found':
      return t.maStateFound;
    case 'safe':
      return t.maStateSafe;
    case 'closed':
      return t.maStateClosed;
    case 'expired':
      return t.maStateExpired;
    default:
      return t.maStateRemoved;
  }
}

/// "2 h ago" style, Bangla digits in Bangla.
String maAgo(BuildContext context, String? iso) {
  final t = AppLocalizations.of(context);
  final at = DateTime.tryParse(iso ?? '');
  if (at == null) return '';
  final d = DateTime.now().toUtc().difference(at.toUtc());
  if (d.inMinutes < 60) return maD(context, t.maAgoMin(d.inMinutes < 1 ? 1 : d.inMinutes));
  if (d.inHours < 48) return maD(context, t.maAgoHours(d.inHours));
  return maD(context, t.maAgoDays(d.inDays));
}

/// Local date + time, digits localised.
String maWhen(BuildContext context, String? iso) {
  final at = DateTime.tryParse(iso ?? '')?.toLocal();
  if (at == null) return '';
  final loc = MaterialLocalizations.of(context);
  return maD(context,
      '${loc.formatMediumDate(at)}, ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(at))}');
}

Color maStateColor(ColorScheme s, String state) {
  switch (state) {
    case 'active':
      return s.error;
    case 'found':
    case 'safe':
      return s.primary;
    default:
      return s.onSurfaceVariant;
  }
}

/// The alert photo (signed, short-lived link) or a neutral placeholder.
class MaPhoto extends StatelessWidget {
  const MaPhoto({super.key, required this.url, this.size = 64, this.label});
  final String? url;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final ph = Container(
      width: size,
      height: size,
      color: s.surfaceContainerHighest,
      child: Icon(Icons.person_rounded, size: size * .55, color: s.onSurfaceVariant),
    );
    return Semantics(
      image: true,
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: (url == null || url!.isEmpty)
            ? ph
            : Image.network(url!, width: size, height: size, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ph),
      ),
    );
  }
}

/// One-tap 999 from the user's OWN dialer (never auto-dials).
Future<void> maDial999(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ok = await launchUrl(Uri(scheme: 'tel', path: '999'));
    if (!ok) messenger.showSnackBar(SnackBar(content: Text(t.maDialFailed)));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(t.maDialFailed)));
  }
}

class Ma999Button extends StatelessWidget {
  const Ma999Button({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return OutlinedButton.icon(
      key: const ValueKey('ma-999'),
      onPressed: () => maDial999(context),
      icon: const Icon(Icons.local_phone_rounded),
      label: Text(t.maCall999),
    );
  }
}

/// The honest "who gets this alert" card (hub, post form, opt-in screen).
class MaWhoGetsCard extends StatelessWidget {
  const MaWhoGetsCard({super.key});

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
            Icon(Icons.info_outline_rounded, color: s.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.maWhoGetsTitle, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.maWhoGetsBody),
        ]),
      ),
    );
  }
}

/// A small error state with a retry button.
class MaError extends StatelessWidget {
  const MaError({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.wifi_off_rounded, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(t.maLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton(onPressed: onRetry, child: Text(t.maRetry)),
      ]),
    );
  }
}
