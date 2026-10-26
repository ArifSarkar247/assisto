import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'retention_source.dart';

/// retention1 shared pieces: the 30-second guide, kind / channel / status /
/// reason wording, the small stat tile.

String rtLang(BuildContext context) => Localizations.localeOf(context).languageCode;

const rtKinds = ['thanks_review', 'winback', 'khata_due', 'back_in_stock', 'birthday'];
const rtChannels = ['in_app', 'whatsapp', 'messenger', 'sms'];

IconData rtKindIcon(String kind) => switch (kind) {
      'thanks_review' => Icons.favorite_outline_rounded,
      'winback' => Icons.waving_hand_outlined,
      'khata_due' => Icons.menu_book_rounded,
      'back_in_stock' => Icons.inventory_2_outlined,
      'birthday' => Icons.cake_outlined,
      _ => Icons.autorenew_rounded,
    };

String rtKindTitle(AppLocalizations t, String kind) => switch (kind) {
      'thanks_review' => t.rtKindThanks,
      'winback' => t.rtKindWinback,
      'khata_due' => t.rtKindKhata,
      'back_in_stock' => t.rtKindStock,
      'birthday' => t.rtKindBirthday,
      _ => kind,
    };

String rtKindDesc(AppLocalizations t, String kind) => switch (kind) {
      'thanks_review' => t.rtKindThanksDesc,
      'winback' => t.rtKindWinbackDesc,
      'khata_due' => t.rtKindKhataDesc,
      'back_in_stock' => t.rtKindStockDesc,
      'birthday' => t.rtKindBirthdayDesc,
      _ => '',
    };

/// "2 days after a purchase" etc. for an automation row.
String rtKindWhen(AppLocalizations t, String lang, String kind, Map<String, dynamic> params) {
  String d(String k, int fb) => rtDigits(lang, rtInt(params[k], fb));
  return switch (kind) {
    'thanks_review' => t.rtKindThanksWhen(d('days_after', 2)),
    'winback' => t.rtKindWinbackWhen(d('days_without', 45)),
    'khata_due' => t.rtKindKhataWhen(d('every_days', 14), d('min_due_taka', 100)),
    'back_in_stock' => t.rtKindStockWhen,
    'birthday' => t.rtKindBirthdayWhen,
    _ => '',
  };
}

IconData rtChannelIcon(String ch) => switch (ch) {
      'whatsapp' => Icons.chat_rounded,
      'messenger' => Icons.forum_rounded,
      'sms' => Icons.sms_outlined,
      _ => Icons.notifications_active_outlined,
    };

String rtChannelName(AppLocalizations t, String ch) => switch (ch) {
      'whatsapp' => t.rtChWhatsApp,
      'messenger' => t.rtChMessenger,
      'sms' => t.rtChSms,
      _ => t.rtChInApp,
    };

String rtChannelDesc(AppLocalizations t, String ch) => switch (ch) {
      'whatsapp' => t.rtChWhatsAppDesc,
      'messenger' => t.rtChMessengerDesc,
      'sms' => t.rtChSmsDesc,
      _ => t.rtChInAppDesc,
    };

String rtStatusName(AppLocalizations t, String st) => switch (st) {
      'sent' => t.rtStSent,
      'delivered' => t.rtStDelivered,
      'read' => t.rtStRead,
      'failed' => t.rtStFailed,
      'skipped' => t.rtStSkipped,
      _ => t.rtStBlocked,
    };

Color rtStatusColor(String st) => switch (st) {
      'sent' || 'delivered' || 'read' => Brand.success,
      'failed' => Brand.danger,
      _ => Brand.warning,
    };

/// Plain-words reason a message did not go.
String rtReason(AppLocalizations t, String r) {
  if (r.startsWith('sms:') || r.startsWith('error:')) return t.rtStFailed;
  return switch (r) {
    'not_on_assisto' => t.rtRsNotOnAssisto,
    'recipient_not_enabled' => t.rtRsRecipientOff,
    'outside_24h_window_template_required' => t.rtRs24h,
    'outside_24h_window' => t.rtRsOutside24h,
    'template_not_approved' => t.rtRsTplNotApproved,
    'promo_in_utility_template' => t.rtRsPromoUtility,
    'template_needs_stop_option' => t.rtRsTplStop,
    'insufficient_credits' || 'guard_over' => t.rtRsCredits,
    'whatsapp_not_connected' || 'sms_not_connected' || 'no_channel' || 'no_token' => t.rtRsNoChannel,
    'no_chat_on_channel' => t.rtRsNoChat,
    'bad_phone' => t.rtRsBadPhone,
    _ => t.rtRsOther,
  };
}

/// Short date + time of a server ISO stamp in the UI locale.
String rtWhen(BuildContext context, Object? iso) {
  final dt = DateTime.tryParse((iso ?? '').toString())?.toLocal();
  if (dt == null) return '';
  final loc = MaterialLocalizations.of(context);
  return '${loc.formatShortDate(dt)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt))}';
}

/// The 3-step "how it works" explainer (first run + the help button).
class RetentionGuideCard extends StatelessWidget {
  final VoidCallback? onClose;
  const RetentionGuideCard({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, size: 20, color: scheme.onPrimaryContainer)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(body),
            ])),
          ]),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.rtGuideTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          step(Icons.touch_app_outlined, t.rtGuide1Title, t.rtGuide1Body),
          step(Icons.edit_note_rounded, t.rtGuide2Title, t.rtGuide2Body),
          step(Icons.insights_rounded, t.rtGuide3Title, t.rtGuide3Body),
          const SizedBox(height: 4),
          Text(t.rtGuideRules, style: Theme.of(context).textTheme.bodySmall),
          if (onClose != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: onClose,
                  child: Text(t.rtGuideGotIt)),
            ),
        ]),
      ),
    );
  }
}

/// A labelled number (results grid, automation card).
class RtStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const RtStat({super.key, required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

/// Centered full-screen message (feature off / error / plan needed).
class RtMessage extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const RtMessage({super.key, required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(32), children: [
      const SizedBox(height: 40),
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 20), Center(child: action!)],
    ]);
  }
}

void rtSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
