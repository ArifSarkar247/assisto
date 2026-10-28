import 'api.dart';

/// tagada2 — the CUSTOMER side of the digital khata ("My Dues"). Any signed-in
/// Assisto user sees what shops recorded for THEIR VERIFIED phone number only
/// (never an unverified match; never the shop's private notes or photos).
/// Paths are under `api/v1/me/dues`. Money comes pre-formatted as `{bn,en}`
/// display pairs from the server. Assisto never takes or moves money.
extension DuesApi on ApiClient {
  /// GET /me/dues -> {verified, phone_masked, shops:[{business_id, shop_name,
  /// balance_poisha, balance_display{bn,en}, status{bn,en}, owes, last_entry_at,
  /// unread, muted, blocked}], total_display{bn,en}}.
  Future<Map<String, dynamic>> myDues() => getJson('/me/dues');

  /// GET /me/dues/<business> -> {shop{id,name}, balance_poisha,
  /// balance_display, status, entries:[{at, kind:'due'|'paid',
  /// amount_display{bn,en}, note}], pay:{methods:[{provider, number, kind}]},
  /// muted, blocked}.
  Future<Map<String, dynamic>> myDuesShop(int businessId) =>
      getJson('/me/dues/$businessId');

  /// POST /me/dues/<business>/prefs {muted?, blocked?} -> {muted, blocked}.
  Future<Map<String, dynamic>> myDuesPrefs(int businessId,
          {bool? muted, bool? blocked}) =>
      postJson('/me/dues/$businessId/prefs', {
        if (muted != null) 'muted': muted,
        if (blocked != null) 'blocked': blocked,
      });

  /// GET /me/dues/<business>/chat -> {messages:[{id, from, kind, text, at,
  /// read}], blocked?}.
  Future<Map<String, dynamic>> myDuesChat(int businessId) =>
      getJson('/me/dues/$businessId/chat');

  /// POST /me/dues/<business>/chat {text} -> {ok, message} or a refusal
  /// (raw + `_status`, e.g. 409 blocked).
  Future<Map<String, dynamic>> myDuesChatSend(int businessId, String text) =>
      postJsonRaw('/me/dues/$businessId/chat', {'text': text});
}
