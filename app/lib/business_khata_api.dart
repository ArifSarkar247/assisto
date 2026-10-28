import 'api.dart';

/// Digital Khata + Cashbox + Business profile API surface (plan §1/§2).
///
/// Implemented as an EXTENSION on [ApiClient] (built only on the public
/// getJson / postJson helpers + the shared lang header) so these screens ship
/// WITHOUT editing api.dart — the integrator SHOULD later fold these into
/// ApiClient proper; the signatures + paths below are authoritative. Every path
/// is under `api/v1/business/` (AppConfig prepends `/api/v1`). All money is
/// handed to/from the server as integer **poisha**; the server's pure logic
/// returns the pre-formatted `{bn,en}` display pairs (fmt_amount, balance_status,
/// tagada_message …) which the UI shows directly — never re-translated here.
extension BusinessKhataApi on ApiClient {
  // ======================= businesses (plan §1) ==========================

  /// GET /business/profiles -> {businesses:[{id, name, type, role, is_premium,
  /// currency, pay_hint?}], selected_id?}. A user may own several; each is its
  /// own books-set.
  Future<Map<String, dynamic>> businessList() => getJson('/business/profiles');

  /// POST /business/profiles {name, type, config?} -> the created business.
  /// type ∈ online_seller|small_shop|service|food|wholesaler|b2b.
  Future<Map<String, dynamic>> businessCreate({
    required String name,
    required String type,
    Map<String, dynamic>? config,
  }) =>
      postJson('/business/profiles', {
        'name': name,
        'type': type,
        if (config != null) 'config': config,
      });

  /// POST /business/profiles/select {business_id} -> the selected business.
  /// Persists which books-set subsequent khata/cashbox calls act on.
  Future<Map<String, dynamic>> businessSelect(int businessId) =>
      postJson('/business/profiles/select', {'business_id': businessId});

  // ======================= khata parties ================================

  /// GET /business/khata/parties?business_id=&book=customer|supplier ->
  /// {parties:[{id, name, phone, area, vip, balance_poisha, balance_display{bn,en},
  /// balance_status{bn,en}}]}. `book=supplier` is owner-only server-side.
  Future<Map<String, dynamic>> khataParties(int businessId, String book) =>
      getJson('/business/khata/parties?business=$businessId&book=$book');

  /// POST /business/khata/parties -> the created party (incl. zeroed balance).
  /// book ∈ customer|supplier (supplier owner-only).
  Future<Map<String, dynamic>> khataCreateParty({
    required int businessId,
    required String book,
    required String name,
    String phone = '',
    String area = '',
    String note = '',
    bool vip = false,
  }) =>
      postJson('/business/khata/parties', {
        'business': businessId,
        'book': book,
        'name': name,
        'phone': phone,
        'area': area,
        'note': note,
        'vip': vip,
      });

  /// GET /business/khata/parties/<id>/statement -> {party, book, lines:[{at,
  /// particulars, debit_poisha, credit_poisha, balance_poisha, *_display{bn,en}}],
  /// opening_display{bn,en}, closing_display{bn,en}, totals{...}}. Fed by the
  /// pure party_statement fn. Supplier party owner-only.
  Future<Map<String, dynamic>> khataStatement(int partyId) =>
      getJson('/business/khata/parties/$partyId/statement');

  /// POST /business/khata/parties/<id>/entries -> {entry, balance_poisha,
  /// balance_display{bn,en}, balance_status{bn,en}, entry_added_message{bn,en}?}.
  /// direction is owner-POV: 'gave' | 'got'. amountPoisha > 0. If
  /// notifyCustomer and this is a customer book, the server returns the
  /// entry_added_message pair to share.
  Future<Map<String, dynamic>> khataAddEntry({
    required int partyId,
    required String direction,
    required int amountPoisha,
    String note = '',
    String? atIso,
    bool notifyCustomer = false,
    String? clientId,
  }) =>
      postJson('/business/khata/parties/$partyId/entries', {
        if (clientId != null) 'client_id': clientId,
        'direction': direction,
        'amount': amountPoisha,
        'note': note,
        if (atIso != null) 'at': atIso,
        'notify_customer': notifyCustomer,
      });

  /// POST /business/khata/parties/<id>/payment -> same shape as addEntry.
  /// A partial/full payment settling a due (pure apply_payment). amountPoisha>0.
  Future<Map<String, dynamic>> khataPayment({
    required int partyId,
    required int amountPoisha,
    String note = '',
    String? atIso,
    String? clientId,
  }) =>
      postJson('/business/khata/parties/$partyId/payment', {
        if (clientId != null) 'client_id': clientId,
        'amount': amountPoisha,
        'note': note,
        if (atIso != null) 'at': atIso,
      });

  /// GET /business/khata/net-position?business_id= -> {receivable_display{bn,en},
  /// payable_display{bn,en}, customer_advances_display{bn,en},
  /// supplier_advances_display{bn,en}, net_display{bn,en}, net_status{bn,en},
  /// ahead:bool}. Supplier figures are omitted/zeroed for staff server-side.
  Future<Map<String, dynamic>> khataNetPosition(int businessId) =>
      getJson('/business/khata/net-position?business=$businessId');

  // ======================= tagada (reminders) ===========================

  /// POST /business/khata/tagada/single {party_id, preset, channel} ->
  /// {message{bn,en}, share:{whatsapp:{available, url?}, sms:{available,
  /// reason{bn,en}?}}, pay_hint{bn,en}?}. channel ∈ whatsapp_share|sms.
  /// preset ∈ polite|reminder|firm|thanks. Pure plan_tagada_single.
  Future<Map<String, dynamic>> tagadaSingle({
    required int partyId,
    required String preset,
    String channel = 'whatsapp_share',
  }) =>
      postJson('/business/khata/tagada/single/$partyId', {
        'preset': preset,
        'channel': channel,
      });

  /// POST /business/khata/tagada/bulk {business_id, party_ids[], preset, channel}
  /// -> {reminders:[{party_id, name, message{bn,en}, share{...}}]}. Pure
  /// plan_tagada_bulk — one descriptor per party the owner can fan out.
  /// ledger100: -> {reminders:[{party_id, name, phone, phone_ok,
  /// balance_poisha, balance_display{bn,en}, message (one language), wa_url,
  /// sms_uri, sms_segments, sms_credits}], skipped:[{party_id, reason}],
  /// sms:{ready, available, owner_only, balance, per_segment}}. ONE
  /// reminder per customer — the app sends them one by one.
  Future<Map<String, dynamic>> tagadaBulk({
    required int businessId,
    required List<int> partyIds,
    required String preset,
    String channel = 'whatsapp_share',
    Map<String, String>? payHint,
  }) =>
      postJson('/business/khata/tagada/bulk', {
        'business': businessId,
        'party_ids': partyIds,
        'preset': preset,
        'channel': channel,
        if (payHint != null) 'pay_hint': payHint,
      });

  /// smsotp/ledger100: POST tagada/sms/<party> — ASSISTO sends the SMS
  /// (owner only, credits per segment, refused at 0 credits). Returns the
  /// raw body + `_status` (never throws on a refusal) so the screen can
  /// show the server's honest reason.
  Future<Map<String, dynamic>> tagadaSendSms({
    required int businessId,
    required int partyId,
    required String preset,
    Map<String, String>? payHint,
  }) =>
      postJsonRaw('/business/khata/tagada/sms/$partyId', {
        'business': businessId,
        'preset': preset,
        if (payHint != null) 'pay_hint': payHint,
      });

  /// ledger100: POST entries/<id> {amount?, note?, at?, base_version} —
  /// owner edit; 409 `conflict` when the server row moved on.
  Future<Map<String, dynamic>> khataEditEntry({
    required int businessId,
    required int entryId,
    required int baseVersion,
    int? amountPoisha,
    String? note,
    String? atIso,
  }) =>
      postJson('/business/khata/entries/$entryId', {
        'business': businessId,
        'base_version': baseVersion,
        if (amountPoisha != null) 'amount': amountPoisha,
        if (note != null) 'note': note,
        if (atIso != null) 'at': atIso,
      });

  /// ledger100: DELETE tagada/schedule/<id>.
  Future<Map<String, dynamic>> tagadaDeleteSchedule(int businessId, int id) =>
      deleteJson('/business/khata/tagada/schedule/$id?business=$businessId');

  /// ledger100: POST tagada/schedule/<id> {ack:true} — the owner sent it.
  Future<Map<String, dynamic>> tagadaAckSchedule(int businessId, int id) =>
      postJson('/business/khata/tagada/schedule/$id',
          {'business': businessId, 'ack': true});

  /// GET /business/khata/tagada/schedule?business_id= -> {schedules:[{id,
  /// party_id, party_name, preset, channel, next_at, interval_days, enabled}]}.
  Future<Map<String, dynamic>> tagadaSchedules(int businessId) =>
      getJson('/business/khata/tagada/schedule?business=$businessId');

  /// POST /business/khata/tagada/schedule {party_id, preset, channel,
  /// interval_days, next_at, enabled} -> the created/updated schedule. A
  /// cron/worker fires it and advances next_at.
  Future<Map<String, dynamic>> tagadaSaveSchedule(Map<String, dynamic> body) =>
      postJson('/business/khata/tagada/schedule', body);

  // ======================= tagada2: send order + chat + invite + SMS =====

  /// tagada2: POST tagada/send/<party> {business, channel, preset, pay_hint?}.
  /// channel ∈ assisto | whatsapp | own_sms | gateway_sms. The SERVER picks
  /// what is allowed (verified-phone match only, 1 reminder per customer per
  /// day across every channel, STOP / quiet hours, SMS balance). Returns the
  /// raw body + `_status` (never throws on a refusal): {ok, channel, url?,
  /// parts?, sms?, reason?, detail?}.
  Future<Map<String, dynamic>> tagadaSend({
    required int businessId,
    required int partyId,
    required String channel,
    required String preset,
    Map<String, String>? payHint,
  }) =>
      postJsonRaw('/business/khata/tagada/send/$partyId', {
        'business': businessId,
        'channel': channel,
        'preset': preset,
        if (payHint != null) 'pay_hint': payHint,
      });

  /// tagada2: GET parties/<id>/chat -> {assisto_user, reachable, party,
  /// messages:[{id, from:'shop'|'customer', kind, text, at, read}]}.
  Future<Map<String, dynamic>> khataChat(int businessId, int partyId) =>
      getJson('/business/khata/parties/$partyId/chat?business=$businessId');

  /// tagada2: POST parties/<id>/chat {business, text} -> {ok, message} or a
  /// refusal (raw + `_status`).
  Future<Map<String, dynamic>> khataChatSend(
          int businessId, int partyId, String text) =>
      postJsonRaw('/business/khata/parties/$partyId/chat',
          {'business': businessId, 'text': text});

  /// tagada2: GET parties/<id>/invite -> {status: none|invited|joined}.
  Future<Map<String, dynamic>> khataInviteStatus(int businessId, int partyId) =>
      getJson('/business/khata/parties/$partyId/invite?business=$businessId');

  /// tagada2: POST parties/<id>/invite -> {status, code, link, share_text,
  /// wa_url, sms_uri} (raw + `_status`).
  Future<Map<String, dynamic>> khataInvite(int businessId, int partyId) =>
      postJsonRaw('/business/khata/parties/$partyId/invite',
          {'business': businessId});

  /// tagada2: GET business/sms/balance -> {allowance_total, allowance_left,
  /// allowance_month, pack_left, parts_left, low, low_threshold, ready,
  /// packs_on_sale, packs:[{sku, parts, price_bdt, on_sale, play_product_id}]}.
  Future<Map<String, dynamic>> smsBalance(int businessId) =>
      getJson('/business/sms/balance?business=$businessId');

  // ======================= cashbox (plan §2) ============================

  /// GET /business/cashbox/<day>?business_id= -> {day, opening_poisha,
  /// opening_display{bn,en}, total_in_display{bn,en}, total_out_display{bn,en},
  /// expected_poisha, expected_display{bn,en}, counted_display{bn,en}?,
  /// variance_display{bn,en}?, variance_status{bn,en}?, reconciled:bool,
  /// entries:[{id, kind, note, ref, at, amount_display{bn,en}}]}. day=YYYY-MM-DD.
  /// Pure cashbox_summary.
  Future<Map<String, dynamic>> cashboxDay(int businessId, String day) =>
      getJson('/business/cashbox/$day?business_id=$businessId');

  /// POST /business/cashbox/<day>/opening {business_id, opening} -> summary.
  /// Sets the day's opening cash (poisha). (Opening is part of the day row; if
  /// the backend folds this into the day GET it may omit this route — keep it
  /// for the "set opening" action.)
  Future<Map<String, dynamic>> cashboxSetOpening({
    required int businessId,
    required String day,
    required int openingPoisha,
  }) =>
      postJson('/business/cashbox/$day/opening', {
        'business_id': businessId,
        'opening': openingPoisha,
      });

  /// POST /business/cashbox/<day>/entries {business_id, kind, amount, note, ref?,
  /// at?} -> updated cashbox summary. kind ∈ in|out. amount poisha > 0. Pure
  /// cash_entry (validate) then persist.
  Future<Map<String, dynamic>> cashboxAddEntry({
    required int businessId,
    required String day,
    required String kind,
    required int amountPoisha,
    String note = '',
    String ref = '',
    String? atIso,
  }) =>
      postJson('/business/cashbox/$day/entries', {
        'business_id': businessId,
        'kind': kind,
        'amount': amountPoisha,
        'note': note,
        'ref': ref,
        if (atIso != null) 'at': atIso,
      });

  /// POST /business/cashbox/<day>/reconcile {business_id, counted} -> updated
  /// summary with variance_display + variance_status. Pure reconcile_cashbox;
  /// persists counted_poisha + reconciled_at.
  Future<Map<String, dynamic>> cashboxReconcile({
    required int businessId,
    required String day,
    required int countedPoisha,
  }) =>
      postJson('/business/cashbox/$day/reconcile', {
        'business_id': businessId,
        'counted': countedPoisha,
      });
}
