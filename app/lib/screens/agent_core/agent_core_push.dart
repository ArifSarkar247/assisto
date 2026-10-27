import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../../config.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../push/push_payload.dart';
import '../../security/secret_store.dart';
import '../../widgets/feature_unavailable.dart';
import 'agent_approvals_screen.dart';

/// agent-core WP-APP: push kind `agent_approval` + its notification actions.
///
/// The push itself carries NO details (it can be read on a locked phone):
/// only "Approval needed", the step's generic label and the approval id. The
/// notification is drawn with lock-screen visibility PRIVATE and two actions:
///
///  * Reject  ([actionReject], showsUserInterface: false) — calls
///    POST /agent-core/approvals/<id> {decision: reject} straight from the
///    notification (also from the background isolate) with the app's OWN auth
///    token (SecretStore 'token'; signed out = nothing is sent). Safe without
///    opening the app: rejecting never sends, pays, books or deletes anything.
///    Success / "already decided" removes the notification; a failure redraws
///    it with "Couldn't reject — open the app" (never a silent fake success).
///  * Approve ([actionApprove], showsUserInterface: true) — does NOT call the
///    API. It opens the app (Android asks to unlock the phone first) on that
///    approval card, which says "you tapped Approve — check and confirm".
///    Why: approving lets the agent message / pay / book / delete, and the
///    user must see exactly what, to whom and the cost (only inside the
///    signed-in app, never on the lock screen) before it happens.
class AgentCorePush {
  AgentCorePush._();

  static const kind = 'agent_approval';
  static const actionApprove = 'ac_approve';
  static const actionReject = 'ac_reject';
  static const route = 'agent_approvals';

  /// Bumped when an `agent_approval` push arrives in the foreground so an
  /// open Approval inbox / agent screen reloads at once.
  static final ValueNotifier<int> approvalsChanged = ValueNotifier<int>(0);

  static bool isApproval(PushPayload p) => p.kind == kind;
  static int? approvalId(PushPayload p) => int.tryParse(p.data['approval_id'] ?? '');

  static void onForegroundPush(PushPayload p) {
    if (isApproval(p)) approvalsChanged.value++;
  }

  /// The two Android actions (labels in the payload's language).
  static List<AndroidNotificationAction> actions(AppLocalizations t) => [
        AndroidNotificationAction(actionReject, t.acNotifReject,
            cancelNotification: false, showsUserInterface: false),
        AndroidNotificationAction(actionApprove, t.acNotifApprove,
            cancelNotification: true, showsUserInterface: true),
      ];

  /// Where a tap / the Approve action lands: the inbox focused on that card,
  /// or the "not available" notice when the flag is off for this user.
  static WidgetBuilder builderFor(PushPayload p, {String? action}) {
    if (!FeatureFlags.instance.routeAllowed(route)) {
      return (_) => const FeatureUnavailableScreen();
    }
    return (_) => AgentApprovalsScreen(
        focusId: approvalId(p), fromApproveAction: action == actionApprove);
  }

  /// Tests: replaces the notification plugin calls.
  @visibleForTesting
  static Future<void> Function(int id)? debugCancel;
  @visibleForTesting
  static Future<void> Function(PushPayload p)? debugRedraw;

  static Future<void> cancelFor(int id) async {
    final n = PushPayload({'kind': kind, 'approval_id': '$id'}).notificationId;
    try {
      final d = debugCancel;
      if (d != null) return await d(n);
      await FlutterLocalNotificationsPlugin().cancel(n);
    } catch (_) {}
  }

  /// Reject action. Returns 'rejected' | 'gone' (already decided / not this
  /// user's / feature off — nothing to do) | 'failed' | 'signed_out'.
  static Future<String> rejectFromNotification(PushPayload p,
      {String? token,
      http.Client? client,
      Future<void> Function(PushPayload failed)? onFailed}) async {
    final id = approvalId(p);
    if (id == null) return 'gone';
    String result;
    try {
      token ??= await SecretStore.instance.read('token');
    } catch (_) {
      token = null;
    }
    if (token == null || token.isEmpty) {
      result = 'signed_out';
    } else {
      try {
        final c = client ?? http.Client();
        final r = await c
            .post(AppConfig.api('/agent-core/approvals/$id'),
                headers: {
                  'Authorization': 'Token $token',
                  'Content-Type': 'application/json',
                  'Accept-Language': p.lang,
                },
                body: jsonEncode({'decision': 'reject'}))
            .timeout(const Duration(seconds: 10));
        if (client == null) c.close();
        if (r.statusCode >= 200 && r.statusCode < 300) {
          result = 'rejected';
        } else if (r.statusCode == 404 || r.statusCode == 403) {
          result = 'gone';
        } else {
          result = 'failed';
        }
      } catch (_) {
        result = 'failed';
      }
    }
    if (result == 'rejected' || result == 'gone') {
      await cancelFor(id);
    } else {
      // honest: the notification stays, now saying it did NOT work
      final failed = PushPayload({
        ...p.data,
        'body': _failText(p.lang),
      });
      try {
        final f = onFailed ?? debugRedraw;
        if (f != null) await f(failed);
      } catch (_) {}
    }
    return result;
  }

  static String _failText(String lang) {
    try {
      return lookupAppLocalizations(Locale(lang == 'en' ? 'en' : 'bn')).acNotifRejectFailed;
    } catch (_) {
      return '';
    }
  }
}
