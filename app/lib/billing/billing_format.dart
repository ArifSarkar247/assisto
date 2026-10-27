import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../widgets/ladder_common.dart' show fmtInt;

/// billapp — the words and numbers of the billing screens, in one place so
/// every screen says the same thing (Bangla digits in the Bangla UI).

bool isBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

String _bnDigits(String s) {
  final b = StringBuffer();
  for (final cu in s.codeUnits) {
    b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? 0x09E6 + (cu - 0x30) : cu);
  }
  return b.toString();
}

/// Digits in the UI's script (for numbers that are not plain ints).
String uiDigits(BuildContext c, String s) => isBn(c) ? _bnDigits(s) : s;

/// "in 2 days" (Bangla in bn) — rounded UP so we never promise sooner than true.
String unlockWhen(BuildContext context, Duration d) {
  final t = AppLocalizations.of(context);
  final mins = d.inMinutes;
  if (mins < 60) return t.billWhenSoon;
  final hours = (mins / 60).ceil();
  if (hours < 24) return t.billWhenHours(fmtInt(context, hours));
  return t.billWhenDays(fmtInt(context, (hours / 24).ceil()));
}

/// "Oct 29, 2026" / Bangla date with Bangla digits.
String billDate(BuildContext context, DateTime d) {
  try {
    return _fix(context, DateFormat.yMMMd(appDateLocale(context)).format(d.toLocal()));
  } catch (_) {
    return _fix(context, DateFormat.yMMMd().format(d.toLocal()));
  }
}

/// "Oct 29, 3:40 PM" style (Bangla day periods come from the app delegate).
String billDateTime(BuildContext context, DateTime d) {
  try {
    return _fix(context,
        DateFormat('d MMM, h:mm a', appDateLocale(context)).format(d.toLocal()));
  } catch (_) {
    return _fix(context, DateFormat('d MMM, h:mm a').format(d.toLocal()));
  }
}

String _fix(BuildContext c, String s) => uiDigits(c, s);

/// "Tk199" / "Tk189.05" style — the amount exactly as the server sent it (never
/// recomputed), with the taka sign for BDT.
String money(BuildContext context, String amount, String currency) {
  final v = double.tryParse(amount) ?? 0;
  final whole = v == v.roundToDouble();
  final s = whole ? fmtInt(context, v.round()) : uiDigits(context, v.toStringAsFixed(2));
  if (currency.toUpperCase() == 'BDT') return '৳$s';
  return '$s ${currency.toUpperCase()}';
}

String bucketLabel(AppLocalizations t, String b) => switch (b) {
      'plan' => t.billBucketPlan,
      'pack' => t.billBucketPack,
      'free' => t.billBucketFree,
      'rewarded' => t.billBucketRewarded,
      'referral' => t.billBucketReferral,
      'debt' => t.billBucketDebt,
      _ => t.billBucketLegacy,
    };

IconData bucketIcon(String b) => switch (b) {
      'plan' => Icons.workspace_premium_rounded,
      'pack' => Icons.shopping_bag_rounded,
      'free' => Icons.card_giftcard_rounded,
      'rewarded' => Icons.ondemand_video_rounded,
      'referral' => Icons.group_add_rounded,
      'debt' => Icons.warning_amber_rounded,
      _ => Icons.account_balance_wallet_rounded,
    };

/// Label for an action-cost code; null = not shown (an internal code the
/// user never triggers directly). Costs themselves always come from the
/// server's action_costs.
String? costLabel(AppLocalizations t, String code) => switch (code) {
      'ai_msg_cheap' => t.billCostAiCheap,
      'ai_msg_medium' => t.billCostAiMedium,
      'ai_msg_strong' => t.billCostAiStrong,
      'scan_ocr' => t.billCostScan,
      'photo_enhance' => t.billCostPhotoEnhance,
      'photo_enhance_cloud' => t.billCostPhotoCloud,
      'photo_prompt_edit' => t.billCostPhotoEdit,
      'photo_generate' => t.billCostPhotoGenerate,
      'photo_colorize' => t.billCostPhotoColorize,
      'photo_old_restore' => t.billCostPhotoRestore,
      'photo_deblur' => t.billCostPhotoDeblur,
      'chat_vision_image' => t.billCostChatPhoto,
      'web_answer' => t.billCostWebAnswer,
      'video_min' => t.billCostVideoMin,
      'sms' => t.billCostSms,
      'ai_sales' => t.billCostAiSales,
      'shop_extra_camera' => t.billCostShopCamera,
      'shop_live_relay_min' => t.billCostShopRelay,
      'vehicle_tracking_month' => t.billCostVehicle,
      'ivr_call' => t.billCostIvr,
      'remote_support_min' => t.billCostRemote,
      _ => null,
    };

/// Localized label for a usage/ledger action code (the ledger `note`).
String actionLabel(AppLocalizations t, String code) {
  if (code.startsWith('photo:')) return t.creditsActionPhotoStudio;
  if (code.startsWith('vision:')) return t.creditsActionChatPhoto;
  final c = costLabel(t, code);
  if (c != null && !code.startsWith('ai_msg')) return c;
  switch (code) {
    case 'ai_msg_cheap':
    case 'ai_msg_medium':
    case 'ai_msg_strong':
    case 'ai_chat':
    case 'ai':
      return t.creditsActionAiChat;
    case 'ai_reply':
    case 'ai_drafting':
      return t.creditsActionAiDraft;
    case 'inbox_summary':
    case 'ai_inbox_summary':
      return t.creditsActionInboxSummary;
    case 'scam_check':
    case 'ai_scam_check':
      return t.creditsActionScamCheck;
    case 'studio':
      return t.creditsActionStudio;
    case 'topup':
    case 'purchase':
      return t.creditsActionTopup;
    case 'rewarded':
    case 'ad_reward':
      return t.creditsActionAdReward;
    case 'monthly_pool':
    case 'included':
      return t.creditsActionMonthlyPool;
    default:
      return t.creditsActionOther;
  }
}

/// What a ledger row means, in plain words (reason + bucket + note).
String ledgerLabel(AppLocalizations t, String reason, String bucket, String note) {
  switch (reason) {
    case 'topup':
      return t.billLedTopup;
    case 'trial':
      return t.billLedTrial;
    case 'rewarded':
      return t.billLedRewarded;
    case 'unlock':
      return t.billLedUnlock;
    case 'expire':
      return t.billLedExpire;
    case 'revoke':
      return t.billLedRevoke;
    case 'refund':
      return t.billLedRefund;
    case 'return':
      return t.billLedReturn;
    case 'adjust':
      return t.billLedAdjust;
    case 'grant':
      return switch (bucket) {
        'plan' => t.billLedPlan,
        'pack' => t.billLedTopup,
        'rewarded' => t.billLedRewarded,
        'referral' => t.billLedReferral,
        _ => t.billLedFree,
      };
    case 'consume':
    case 'spend':
      return actionLabel(t, note);
    default:
      return note.isNotEmpty ? actionLabel(t, note) : actionLabel(t, reason);
  }
}
