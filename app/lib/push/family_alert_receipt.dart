import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../messaging/receipt_ack.dart' show ReceiptAck;

/// family100 — "the alert reached this phone" receipt, from ANY isolate.
///
/// The FIRST thing the FCM background handler and the foreground handler do
/// for a family alert / SOS push: POST /family/alerts/received with its
/// `delivery_id`, using the token stored at sign-in. The server records the
/// receipt time, so (a) the sender sees "received" next to each member and
/// (b) quality bar D/৭ (push -> phone within 60 s) is measured on real
/// phones (`manage.py family_alerts_report`). Best effort: a failed receipt
/// never blocks drawing the alert, and nothing is queued (the "seen" tap
/// later records receipt too).
const kFamilyReceiptKinds = {'sos', 'family_alert'};

/// The delivery id in [data] when it is a family alert push, else null.
int? familyDeliveryId(Map<String, dynamic> data) {
  final kind = '${data['kind'] ?? ''}'.trim();
  if (!kFamilyReceiptKinds.contains(kind)) return null;
  final id = int.tryParse('${data['delivery_id'] ?? ''}'.trim());
  return (id != null && id > 0) ? id : null;
}

Future<bool> ackFamilyAlertReceipt(Map<String, dynamic> data,
    {Future<String?> Function()? token, http.Client? client}) async {
  final id = familyDeliveryId(data);
  if (id == null) return false;
  String? tok;
  try {
    tok = await (token ?? ReceiptAck.storedToken)();
  } catch (_) {
    tok = null;
  }
  if (tok == null || tok.isEmpty) return false;
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(AppConfig.api('/family/alerts/received'),
            headers: {
              'Authorization': 'Token $tok',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'ids': [id]
            }))
        .timeout(const Duration(seconds: 10));
    return r.statusCode >= 200 && r.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    if (client == null) c.close();
  }
}
