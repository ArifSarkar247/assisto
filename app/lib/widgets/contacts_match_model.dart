import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Contact-match + invite ADVANCED (#99/#101, SPEC §21) — small value types +
/// a key→getter label switch shared by [ContactsScreen] and the
/// contacts_match_* widgets.
///
/// All copy now lives in the ARB (AppLocalizations); the former bilingual
/// `_cm` table was merged into app_en.arb / app_bn.arb. Parameterized keys
/// (cmResultsFoundCount, cmHashedOnDevice, cmInviteCardReferral) are called
/// via their generated placeholder methods directly, not through [cmLabel].

bool cmIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer with Bangla digits (codepoints) when the locale is bn.
String cmNum(BuildContext c, int n) {
  if (!cmIsBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Resolve a static (non-parameterized) `cm*` key to its ARB getter. Lets the
/// widgets keep looking strings up by key (including dynamically, e.g. phase
/// labels and disclosure facts) while the copy lives in AppLocalizations.
String cmLabel(BuildContext c, String key) {
  final t = AppLocalizations.of(c);
  switch (key) {
    case 'cmDiscWhyTitle':
      return t.cmDiscWhyTitle;
    case 'cmDiscWhyBody':
      return t.cmDiscWhyBody;
    case 'cmDiscSendTitle':
      return t.cmDiscSendTitle;
    case 'cmDiscSendBody':
      return t.cmDiscSendBody;
    case 'cmDiscStoreTitle':
      return t.cmDiscStoreTitle;
    case 'cmDiscStoreBody':
      return t.cmDiscStoreBody;
    case 'cmDiscControlTitle':
      return t.cmDiscControlTitle;
    case 'cmDiscControlBody':
      return t.cmDiscControlBody;
    case 'cmPrivacyExplainerTitle':
      return t.cmPrivacyExplainerTitle;
    case 'cmPrivacyLearnMore':
      return t.cmPrivacyLearnMore;
    case 'cmPrivacyStep1':
      return t.cmPrivacyStep1;
    case 'cmPrivacyStep2':
      return t.cmPrivacyStep2;
    case 'cmPrivacyStep3':
      return t.cmPrivacyStep3;
    case 'cmPrivacyStep4':
      return t.cmPrivacyStep4;
    case 'cmResultsFoundTitle':
      return t.cmResultsFoundTitle;
    case 'cmInviteOthersTitle':
      return t.cmInviteOthersTitle;
    case 'cmReSync':
      return t.cmReSync;
    case 'cmReSyncHint':
      return t.cmReSyncHint;
    case 'cmPhaseReading':
      return t.cmPhaseReading;
    case 'cmPhaseHashing':
      return t.cmPhaseHashing;
    case 'cmPhaseMatching':
      return t.cmPhaseMatching;
    case 'cmDeniedTitle':
      return t.cmDeniedTitle;
    case 'cmDeniedBody':
      return t.cmDeniedBody;
    case 'cmOpenSettings':
      return t.cmOpenSettings;
    case 'cmOfflineTitle':
      return t.cmOfflineTitle;
    case 'cmOfflineBody':
      return t.cmOfflineBody;
    case 'cmRetry':
      return t.cmRetry;
    case 'cmInviteCardTitle':
      return t.cmInviteCardTitle;
    case 'cmInviteCardBody':
      return t.cmInviteCardBody;
    case 'cmInviteCardReferralNote':
      return t.cmInviteCardReferralNote;
    case 'cmInviteCardSeeReferral':
      return t.cmInviteCardSeeReferral;
    case 'cmInviteCopyLink':
      return t.cmInviteCopyLink;
    case 'cmInviteLinkCopied':
      return t.cmInviteLinkCopied;
    case 'cmShareCard':
      return t.cmShareCard;
    case 'cmInviteFromContacts':
      return t.cmInviteFromContacts;
    case 'cmInviteNoneTitle':
      return t.cmInviteNoneTitle;
    case 'cmInviteNoneBody':
      return t.cmInviteNoneBody;
    default:
      return key;
  }
}

/// Where the flow currently is. Drives the single-screen state machine so
/// every SPEC §21 state (empty / loading / permission / offline / results) is
/// an explicit, designed branch — nothing raw.
enum CmStage {
  /// First run / re-entry before consent — the Play disclosure.
  disclosure,

  /// Hashing on-device + uploading the salted batch + matching.
  matching,

  /// Done — show on-Assisto (connect) + invite-others.
  results,

  /// OS contacts permission was denied (or revoked) — recoverable.
  denied,

  /// The match call failed with no connectivity — recoverable (retry).
  offline,
}

/// How far the on-device hashing + match has progressed, for the loading UI
/// (SPEC §21 #4 — a real progress state, not a bare spinner).
class CmProgress {
  const CmProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
  });

  final CmPhase phase;
  final int done;
  final int total;

  double? get fraction =>
      total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  CmProgress copyWith({CmPhase? phase, int? done, int? total}) => CmProgress(
        phase: phase ?? this.phase,
        done: done ?? this.done,
        total: total ?? this.total,
      );
}

enum CmPhase { reading, hashing, matching }

/// Data for the shareable invite card (#101) — carries the user's referral code
/// so an accepted invite credits referral points.
class CmInviteCard {
  const CmInviteCard({
    required this.link,
    this.referralCode = '',
    this.inviterName = '',
    this.text = '',
  });

  final String link;
  final String referralCode;
  final String inviterName;
  final String text;

  bool get hasReferral => referralCode.isNotEmpty;
}

