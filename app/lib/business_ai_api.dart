import 'api.dart';

/// Business v2 — AI Sales Assistant client surface.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public methods
/// (getJson / postJson) so this module ships WITHOUT editing the shared
/// api.dart. The integrator SHOULD later fold these into ApiClient proper — the
/// signatures and paths below are authoritative and match
/// `.phaseB/biz_ai_integration.md` §(b).
///
/// Gating legend used in the docstrings below:
///   FREE  — bookkeeping / selling / order status (always available)
///   PAID  — Business AI plan (server returns upgrade-required when unpaid)
///   KEY   — needs a live provider key; otherwise the backend returns a mock /
///           degraded payload (never fails for lack of a key).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`, so every
/// endpoint returns bn/en-aware text.
///
/// PAID endpoints can return HTTP 402 (payment required) / 403 with a body like
/// `{"upgrade_required": true, "plan": "business", ...}`. Callers should catch
/// [ApiException] and, when [isUpgradeRequired] is true, show the upgrade gate
/// instead of a generic error. See [aiReplyGuarded] for the convenience form.
extension BusinessAiApi on ApiClient {
  // ---------------------------------------------------------------- AI assistant

  /// POST /business/ai/reply {thread_id?, text, owner_takeover?}
  /// -> {text, confidence, needs_human, handoff_reason, is_ai, disclosure}.
  /// PAID · KEY(LLM). No key -> deterministic mock draft. The provider MUST NOT
  /// invent price/stock (enforced server-side via the real catalog context).
  Future<Map<String, dynamic>> aiDraftReply({
    int? threadId,
    required String text,
    bool ownerTakeover = false,
  }) =>
      postJson('/business/ai/reply', {
        if (threadId != null) 'thread_id': threadId,
        'text': text,
        'owner_takeover': ownerTakeover,
      });

  /// POST /business/ai/bargain {product_id, offer, lang?}
  /// -> {decision: accept_list|accept_offer|counter|defer, price?, text,
  ///     free_delivery}. PAID. NO key — pure code, NEVER AI, and NEVER returns a
  /// price below the product's min_price (below-min -> decision=`defer`).
  Future<Map<String, dynamic>> aiBargain({
    required int productId,
    required num offer,
  }) =>
      postJson('/business/ai/bargain', {
        'product_id': productId,
        'offer': offer,
      });

  /// POST /business/ai/disclose -> {short, full}. PAID. The AI-disclosure line
  /// ("I'm the shop's AI assistant") — shown in the console + sent if a customer
  /// asks whether they're talking to a human.
  Future<Map<String, dynamic>> aiDisclosure() =>
      postJson('/business/ai/disclose', const {});

  /// GET /business/ai/morning-summary -> {msgs, orders, need, text}. PAID.
  Future<Map<String, dynamic>> aiMorningSummary() =>
      getJson('/business/ai/morning-summary');

  // ---------------------------------------------------------------- chat inbox

  /// GET /business/ai/threads -> {threads:[{id, customer_phone, customer_name,
  /// channel, last_inbound_at, owner_takeover, lang, unread, last_text,
  /// needs_human}]}. PAID. `channel` is `whatsapp_cloud`|`messenger` ONLY —
  /// official platforms, never personal WhatsApp.
  Future<List<Map<String, dynamic>>> aiThreads() async {
    final r = await getJson('/business/ai/threads');
    return ((r['threads'] ?? r['results'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// GET /business/ai/threads/{id} -> {thread{...}, messages:[{id, direction,
  /// text, is_ai, confidence, needs_human, handoff_reason, created_at}]}. PAID.
  Future<Map<String, dynamic>> aiThread(int id) =>
      getJson('/business/ai/threads/$id');

  /// POST /business/ai/threads/{id}/takeover {on} -> {owner_takeover}. PAID.
  /// Owner takes over (or hands back) a single chat. While on, the AI drafts
  /// nothing and only the owner's typed messages go out.
  Future<Map<String, dynamic>> aiThreadTakeover(int id, bool on) =>
      postJson('/business/ai/threads/$id/takeover', {'on': on});

  /// POST /business/ai/threads/{id}/send {text, from_ai?} -> {sent, needs_key}.
  /// PAID · KEY(Meta token to actually POST). No key -> queued/mock,
  /// `needs_key:true`. Used for the owner's approved / edited reply.
  Future<Map<String, dynamic>> aiThreadSend(
    int id,
    String text, {
    bool fromAi = false,
  }) =>
      postJson('/business/ai/threads/$id/send', {
        'text': text,
        'from_ai': fromAi,
      });

  // ---------------------------------------------------------------- channels (Meta)

  /// GET /business/ai/channels -> {whatsapp_cloud:{connected, number?},
  /// messenger:{connected, page?}}. FREE (status read). Drives the
  /// "connect WhatsApp Business / Messenger" setup state when no Meta keys yet.
  Future<Map<String, dynamic>> aiChannels() =>
      getJson('/business/ai/channels');

  // ---------------------------------------------------------------- bargain rules

  /// GET /business/bargain/rules -> {rules:[{product_id, name, list_price,
  /// min_price, discount_steps:[], free_delivery_over, bundle_min_qty, tone}]}.
  /// PAID. `min_price` is the ENFORCED floor (read-only in the UI).
  Future<List<Map<String, dynamic>>> bargainRules() async {
    final r = await getJson('/business/bargain/rules');
    return ((r['rules'] ?? r['results'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// POST /business/bargain/rules/{productId} {discount_steps, free_delivery_over,
  /// bundle_min_qty, tone} -> saved rule. PAID. The server REFUSES to lower
  /// min_price here — min_price is set on the Product, not in bargaining.
  Future<Map<String, dynamic>> bargainRuleSave(
    int productId,
    Map<String, dynamic> body,
  ) =>
      postJson('/business/bargain/rules/$productId', body);

  // ---------------------------------------------------------------- orders

  /// GET /business/orders -> {orders:[{id, customer_name, total, status,
  /// payment, cod_amount, courier?, tracking?, courier_live, created_at}]}.
  /// FREE. Status machine: new→confirmed→packed→shipped→delivered/returned.
  Future<List<Map<String, dynamic>>> ordersList() async {
    final r = await getJson('/business/orders');
    return ((r['orders'] ?? r['results'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// GET /business/orders/{id} -> a single order with items + timeline. FREE.
  Future<Map<String, dynamic>> order(int id) =>
      getJson('/business/orders/$id');

  /// POST /business/orders/{id}/advance {target, courier?} -> {status,
  /// courier_live, tracking?, needs_key}. FREE for status; KEY(courier) to
  /// actually book `shipped` — truth: this path books nothing -> empty tracking + courier_live:false.
  /// Advancing to `shipped` WITHOUT a courier is refused server-side (4xx).
  Future<Map<String, dynamic>> orderAdvance(
    int id,
    String target, {
    String? courier,
  }) =>
      postJson('/business/orders/$id/advance', {
        'target': target,
        if (courier != null) 'courier': courier,
      });

  /// GET /business/orders/{id}/parcel -> {status, status_label, line, courier?,
  /// tracking?}. FREE. The "where is my parcel?" status (reads stored tracking).
  Future<Map<String, dynamic>> orderParcel(int id) =>
      getJson('/business/orders/$id/parcel');

  // ---------------------------------------------------------------- policies

  /// GET /business/policies -> {delivery_inside, delivery_outside,
  /// free_delivery_over, returns, hours, payment_note}. FREE (feeds AI context).
  Future<Map<String, dynamic>> policies() => getJson('/business/policies');

  /// POST /business/policies {...} -> saved policy. FREE.
  Future<Map<String, dynamic>> policiesSave(Map<String, dynamic> body) =>
      postJson('/business/policies', body);

  // ---------------------------------------------------------------- payments

  /// GET /business/payments/qr -> {provider, merchant_number, merchant_name,
  /// label, holds_funds:false, custodian}. FREE. Owner's OWN merchant — Assisto
  /// stores a POINTER only, never a balance, and is NEVER a wallet.
  Future<Map<String, dynamic>> paymentsQr() =>
      getJson('/business/payments/qr');

  /// POST /business/payments/qr {provider, merchant_number, merchant_name}
  /// -> saved pointer. FREE.
  Future<Map<String, dynamic>> paymentsQrSave(Map<String, dynamic> body) =>
      postJson('/business/payments/qr', body);

  /// POST /business/payments/link {order_id} -> {url, live, needs_key,
  /// holds_funds:false, custodian:"licensed_partner"}. FREE/PAID · KEY(licensed
  /// payment partner). truth: not wired -> empty link, live:false, not_wired:true.
  Future<Map<String, dynamic>> paymentsLink(int orderId) =>
      postJson('/business/payments/link', {'order_id': orderId});

  // ---------------------------------------------------------------- AI extras

  /// POST /business/ai/voice-entry {text} -> {draft{...}, text}. PAID ·
  /// KEY(transcription). A parsed ledger-entry DRAFT for a review step.
  Future<Map<String, dynamic>> aiVoiceEntry(String text) =>
      postJson('/business/ai/voice-entry', {'text': text});

  /// POST /business/ai/paper-khata {rows?} -> {rows:[...], count, text}. PAID ·
  /// KEY(OCR/vision). Mocked rows now; each row is reviewed before saving.
  Future<Map<String, dynamic>> aiPaperKhata({List<Map<String, dynamic>>? rows}) =>
      postJson('/business/ai/paper-khata', {if (rows != null) 'rows': rows});

  /// POST /business/ai/match-payment {notif} -> {matched, name?, amount?,
  /// due_id?, text}. PAID. No key — reuses money parse rules.
  Future<Map<String, dynamic>> aiMatchPayment(String notif) =>
      postJson('/business/ai/match-payment', {'notif': notif});

  /// GET /business/ai/insights -> {insights:[{kind, text}]}. PAID. Rules only.
  Future<List<Map<String, dynamic>>> aiInsights() async {
    final r = await getJson('/business/ai/insights');
    return ((r['insights'] ?? []) as List).cast<Map<String, dynamic>>();
  }
}

/// True when a PAID endpoint refused because the Business AI plan is not active.
/// The backend signals this with HTTP 402/403 and/or `upgrade_required` in the
/// body (surfaced via [ApiException.message]/status). Screens use this to swap
/// the body for the upgrade gate instead of showing an error.
bool isUpgradeRequired(Object error) {
  if (error is! ApiException) return false;
  if (error.status == 402) return true;
  final m = error.message.toLowerCase();
  return m.contains('upgrade') ||
      m.contains('business plan') ||
      m.contains('premium');
}
