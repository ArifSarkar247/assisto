/// f6 — NO SHOWPIECES (owner order 6 part F, permanent rule).
///
/// Nothing a user can tap may be fake, a "coming soon", or a switch that does
/// nothing. A feature that does not really work end-to-end yet keeps its code
/// but its ENTRY POINT is hidden behind one of these gates. Flip a gate to
/// `true` only together with the change that makes the feature real (and its
/// proof test). The list mirrors owner_actions/SHOWPIECES_BN.md.
///
/// Gates that already lived elsewhere before f6 (kept where they are):
///   * FallDetectScreen.engineShipped        — no native fall sensor yet
///   * VaWake.shipped                        — "Hey Assisto" wake word
///   * kProductImportPickerWired             — Excel/CSV product import
///   * kQuoteAcceptPageWired                 — CRM public quote-accept page
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'config.dart';

/// PLAY-NOMED — Google Play: personal developer accounts may NOT publish
/// medical / health apps (Play rejected the "Medication and treatment
/// management" declaration). Until the owner moves the Play listing to an
/// ORGANIZATION account, the PLAY flavour (`--dart-define=PLAY_STORE=true`)
/// hides every dedicated medical entry point: medicine schedules, dose history
/// and missed-dose alerts, the medicine database, the prescription reader and
/// records, the health timeline, the doctor-serial tracker, health-tips and
/// first-aid guidance, and the medical-record fields of the emergency card.
/// The CODE stays; only entry points are hidden. The website APK
/// (playStore == false) is unchanged. Wellness (Health Connect steps / heart
/// rate / sleep, fitness, mood) and plain reminders stay in Play.
///
/// FLIP: when the organization account is approved, return `true` here (or
/// delete the gate) and re-declare the health features in Play Console.
bool get kMedicalFeaturesAllowed =>
    debugMedicalFeaturesOverride ?? !AppConfig.playStore;

/// Test-only override for [kMedicalFeaturesAllowed] (null = follow flavour).
@visibleForTesting
bool? debugMedicalFeaturesOverride;

/// Chat / deep-link routes that open a dedicated medical screen. In Play they
/// are not in ChatNav.routes, so no chat reply, Discover card, push, watch
/// item or quick button can open them.
const Set<String> kMedicalRoutes = {
  'medicine_db',
  'health_tips',
  'health_timeline',
  'doctor_serial',
};

/// In-app message sound / vibration rows (Messenger → Notifications). The app
/// does not play its own in-app sound or vibration yet.
const bool kInAppSoundBuilt = false;

/// Community "mute notifications" menu item. The server does not push
/// community posts yet, so there is nothing to mute.
const bool kCommunityAlertsBuilt = false;

/// Agent Studio automations. They are stored on the phone but nothing ever
/// fires them on schedule or on an event, and the AI "summarize" step is a
/// canned preview — a showpiece. Sidebar + chat route are hidden.
const bool kAgentStudioRunsAutomations = false;

/// Job Hunter discovery feed. No official jobs source is connected, so the
/// curated "sample" job cards (made-up openings) are not shown; the user's own
/// tracked jobs, saved list and tracker stay.
const bool kJobsFeedConnected = false;

/// Live disaster-warning feed (BMD/FFWC). Without the owner-approved official
/// feed the screen shows no example warning cards — only the honest banner,
/// the safety library, the checklist and the hotlines.
const bool kShowSampleDisasterWarnings = false;

/// Used-phone check: the official NEIR stolen-phone registry lookup. Not
/// wired (needs BTRC access), so its "not available yet" card is hidden.
const bool kNeirCheckWired = false;

/// Used-phone check: IMEI TAC -> brand/model data source. Not connected, so
/// no "not available yet" card is shown (and a brand is never guessed).
const bool kTacSourceWired = false;

/// Messenger -> Chats: backup / restore / clear chat history rows. They only
/// showed a snackbar; nothing was sealed, uploaded or deleted. Hidden. (The
/// real passphrase-encrypted backup is Settings -> Encrypted backup.)
const bool kMsgrChatBackupWired = false;

/// Lost/Stolen: the lock / alarm / locate / message switches (and the
/// "remote triggers" card). Saved on the phone but read by nothing, because no
/// remote trigger (SMS command / trusted contact) ships yet. Hidden; the real
/// "test lock / test alarm / report location now" buttons stay.
const bool kLostActionSwitchesWired = false;

/// Settings -> input source permissions. The switches were saved on the server
/// but no ingest path ever checked them. Hidden until ingest enforces them.
const bool kSourcePermissionsEnforced = false;

/// Area community notice board. Posts are stored per user, so neighbours never
/// see them — not a board. Hidden until a shared, moderated area feed exists
/// (a public user-content feed needs the owner's moderation decision).
const bool kAreaBoardShared = false;
