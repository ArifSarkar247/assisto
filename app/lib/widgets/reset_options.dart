import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Account-recovery option tiles + shared banners for the password-reset flow
/// (SPEC v2.1 §21, ADVANCED). UI-only; no network, no Bangla.
///
/// Honesty rules baked in:
///  - EMAIL recovery works now.
///  - SMS code recovery is 🔑 key-gated: shown as "available when an SMS gateway
///    is connected", never as a working button.
///  - Security-question recovery is presented as an opt-in that is "available
///    when you've set one up" — honest about not being configured yet rather
///    than faking a challenge.

/// A recovery channel the request screen can offer.
enum RecoveryChannel { email, sms, securityQuestion }

class ResetChannelTile extends StatelessWidget {
  final RecoveryChannel channel;

  /// true only for channels that are actually usable right now (email).
  final bool available;
  final bool selected;
  final VoidCallback? onTap;
  const ResetChannelTile({
    super.key,
    required this.channel,
    required this.available,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, subtitle) = switch (channel) {
      RecoveryChannel.email => (
          Icons.email_rounded,
          t.resetChannelEmail,
          available ? t.resetChannelEmailReady : t.resetChannelEmailReady,
        ),
      RecoveryChannel.sms => (
          Icons.sms_rounded,
          t.resetChannelSms,
          // 🔑 honest: works only once an SMS gateway is connected (o1-otp)
          available ? t.otpResetSmsReady : t.resetSmsUnavailable,
        ),
      RecoveryChannel.securityQuestion => (
          Icons.help_outline_rounded,
          t.resetChannelSecurityQ,
          t.resetChannelSecurityQNote,
        ),
    };
    return Opacity(
      opacity: available ? 1 : 0.6,
      child: Card(
        color: selected ? scheme.secondaryContainer : null,
        child: ListTile(
          leading: Icon(icon,
              color: available
                  ? scheme.primary
                  : scheme.onSurfaceVariant),
          title: Text(title),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
          trailing: available
              ? (selected
                  ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                  : const Icon(Icons.chevron_right_rounded))
              : Tooltip(
                  message: t.resetChannelLockedTip,
                  child: Icon(Icons.lock_outline_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
          enabled: available,
          onTap: available ? onTap : null,
        ),
      ),
    );
  }
}

/// Honest "too many attempts — wait" banner shown when the backend rate-limits
/// (HTTP 429 on the reset scope, 6/min). Never silently retries.
class ResetRateLimitBanner extends StatelessWidget {
  const ResetRateLimitBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Icon(Icons.timer_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(t.resetTooManyAttempts,
                style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ]),
      ),
    );
  }
}

/// Post-reset "sign out all devices" choice. For a fresh reset the secure
/// default is ON — any session an attacker may have is invalidated. Presented
/// honestly: the actual revoke happens server-side when the reset confirms.
class ResetSignOutAllTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const ResetSignOutAllTile(
      {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.devices_rounded),
        title: Text(t.resetSignOutAll),
        subtitle: Text(t.resetSignOutAllNote,
            style: const TextStyle(fontSize: 12)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
