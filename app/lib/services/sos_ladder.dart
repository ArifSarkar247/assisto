/// sosat — the SOS escalation ladder (mirror of backend
/// core/logic/sos_ladder.py; keep in sync — both unit-tested). The server's
/// GET /family/sos/ladder already returns the stage; this mirror lets the
/// screen move to the next step by itself while it is open (no polling
/// storm) and decide offline.
class SosLadder {
  static const windowS = 30 * 60;
  static const reringAfterS = 120;
  static const suggest999AfterS = 300;

  static const none = 'none',
      noOne = 'no_one',
      waiting = 'waiting',
      rerung = 'rerung',
      call999 = 'call_999',
      seen = 'seen',
      resolved = 'resolved';

  static String stage(List<Map<String, dynamic>> recipients, int? ageS,
      {bool isResolved = false}) {
    if (ageS == null || ageS > windowS) return none;
    if (isResolved) return resolved;
    if (recipients.any((r) => r['seen'] == true)) return seen;
    final reachable = recipients.where((r) =>
        r['status'] == 'sent' || r['status'] == 'held' || r['received'] == true);
    if (reachable.isEmpty) return noOne;
    if (ageS >= suggest999AfterS) return call999;
    if (ageS >= reringAfterS) return rerung;
    return waiting;
  }
}
