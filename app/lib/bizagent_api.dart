import 'api.dart';
import 'payments/payments_api.dart' show payFlavour;

/// P1 — Business AI Agent (F-commerce sellers) client surface.
///
/// An EXTENSION on [ApiClient] built only on getJson/postJson so the shared
/// api.dart stays untouched. Server: backend/core/views_bizagent.py
/// (/api/v1/bizagent/...). Every error is an [ApiException] whose message is
/// the server's honest bn/en `detail` (e.g. "Connect a channel first.").
extension BizAgentApi on ApiClient {
  /// Everything the setup screen needs: settings, channels (no tokens ever),
  /// catalog check, couriers, plan, meta_ready, pending_approvals, kill.
  Future<Map<String, dynamic>> bizAgentSetup() =>
      getJson('/bizagent/setup?flavour=${payFlavour()}');

  Future<Map<String, dynamic>> bizAgentSaveSettings(Map<String, dynamic> body) =>
      postJson('/bizagent/settings', body);

  /// kind: messenger | instagram | whatsapp_cloud. external_id = Page ID /
  /// Instagram account ID / WhatsApp phone_number_id. The server checks the
  /// token with Meta and returns the honest status (connected / error).
  Future<Map<String, dynamic>> bizAgentConnect(
          String kind, String externalId, String token) =>
      postJson('/bizagent/channels',
          {'kind': kind, 'external_id': externalId, 'token': token});

  Future<Map<String, dynamic>> bizAgentToggleChannel(int id, bool enabled) =>
      postJson('/bizagent/channels/$id/toggle', {'enabled': enabled});

  Future<Map<String, dynamic>> bizAgentDeleteChannel(int id) =>
      postJson('/bizagent/channels/$id/delete');

  Future<Map<String, dynamic>> bizAgentSaveCourier(
          String courier, Map<String, dynamic> keys) =>
      postJson('/bizagent/couriers/$courier', keys);

  Future<List<Map<String, dynamic>>> bizAgentApprovals() async {
    final r = await getJson('/bizagent/approvals');
    return ((r['approvals'] ?? const []) as List).cast<Map<String, dynamic>>();
  }

  /// text == null → approve the AI draft as is (billed as one AI reply);
  /// edited text → sent as the seller's own reply.
  Future<Map<String, dynamic>> bizAgentApprove(int id, {String? text}) =>
      postJson('/bizagent/approvals/$id/approve', {if (text != null) 'text': text});

  Future<Map<String, dynamic>> bizAgentReject(int id) =>
      postJson('/bizagent/approvals/$id/reject');

  Future<List<Map<String, dynamic>>> bizAgentThreads() async {
    final r = await getJson('/bizagent/threads');
    return ((r['threads'] ?? const []) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> bizAgentThread(int id) =>
      getJson('/bizagent/threads/$id');

  /// on=true: a person takes over (AI paused on this chat) / false: resume AI.
  Future<Map<String, dynamic>> bizAgentHandover(int id, bool on) =>
      postJson('/bizagent/threads/$id/handover', {'on': on});

  Future<Map<String, dynamic>> bizAgentSend(int id, String text) =>
      postJson('/bizagent/threads/$id/send', {'text': text});

  Future<Map<String, dynamic>> bizAgentBook(int orderId, String courier) =>
      postJson('/bizagent/orders/$orderId/book', {'courier': courier});

  Future<Map<String, dynamic>> bizAgentReports() => getJson('/bizagent/reports');

  Future<Map<String, dynamic>> bizAgentPlan() =>
      getJson('/bizagent/plan?flavour=${payFlavour()}');

  Future<Map<String, dynamic>> bizAgentStartTrial() =>
      postJson('/bizagent/plan/trial');

  /// Gateway checkout for a seller plan → {redirect_url}. The app shows Buy
  /// only while plan['purchasable'] is true (gateway on + configured).
  Future<Map<String, dynamic>> bizAgentCheckout(String plan) =>
      postJson('/bizagent/plan/checkout', {'plan': plan, 'flavour': payFlavour()});

  // ---------------------------------------------------------------- g1
  // Server: backend/core/views_bizagent_g1.py.

  /// Per-chat toggle: 'human' = I will reply (AI silent here) · 'ai' = Let
  /// AI reply (also ends a pause after a human reply).
  Future<Map<String, dynamic>> bizAgentReplyMode(int threadId, String mode) =>
      postJson('/bizagent/threads/$threadId/mode', {'mode': mode});

  Future<Map<String, dynamic>> bizAgentFaqs() => getJson('/bizagent/faqs');

  Future<Map<String, dynamic>> bizAgentAddFaq(String question, String answer) =>
      postJson('/bizagent/faqs', {'question': question, 'answer': answer});

  /// status: approved | suggested | rejected (and/or edited text).
  Future<Map<String, dynamic>> bizAgentEditFaq(int id, Map<String, dynamic> body) =>
      postJson('/bizagent/faqs/$id', body);

  Future<Map<String, dynamic>> bizAgentDeleteFaq(int id) =>
      postJson('/bizagent/faqs/$id/delete');

  /// Suggestions learned from the owner's past replies (never auto-used).
  Future<Map<String, dynamic>> bizAgentLearnFaqs() => postJson('/bizagent/faqs/learn');

  Future<Map<String, dynamic>> bizAgentPostLinks() => getJson('/bizagent/post-links');

  Future<Map<String, dynamic>> bizAgentAddPostLink(String postId, int productId) =>
      postJson('/bizagent/post-links', {'post_id': postId, 'product_id': productId});

  Future<Map<String, dynamic>> bizAgentDeletePostLink(int id) =>
      postJson('/bizagent/post-links/$id/delete');

  /// Chats, orders, revenue the agent brought, AI cost, profit + rules vs AI.
  Future<Map<String, dynamic>> bizAgentReport({int days = 30}) =>
      getJson('/bizagent/agent-report?days=$days');

  Future<Map<String, dynamic>> bizAgentWidget() => getJson('/bizagent/widget');

  Future<Map<String, dynamic>> bizAgentSaveWidget(Map<String, dynamic> body) =>
      postJson('/bizagent/widget', body);

  /// The OWNER marks a customer's payment verified/rejected after checking
  /// their own wallet — a screenshot never confirms a payment.
  Future<Map<String, dynamic>> bizAgentVerifyPayment(int orderId, String status) =>
      postJson('/bizagent/orders/$orderId/payment', {'status': status});

  // ---------------------------------------------------------------- biz-v2
  // Server: backend/core/views_bizagent_v2.py.

  /// Business inbox across every connected channel. status: agent | owner |
  /// attention ('' = all); q searches name, number and message text.
  /// → {threads, counts: {all, agent, owner, attention, unread}, features}
  Future<Map<String, dynamic>> bizAgentInbox(
      {String status = '', String channel = '', String q = '', bool unread = false}) {
    final qp = <String, String>{
      if (status.isNotEmpty) 'status': status,
      if (channel.isNotEmpty) 'channel': channel,
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (unread) 'unread': '1',
    };
    final qs = qp.isEmpty ? '' : '?${Uri(queryParameters: qp).query}';
    return getJson('/bizagent/inbox$qs');
  }

  /// sales2: catalog quick replies for one chat (price/stock cards, delivery,
  /// payment) in the customer's language. Fills the composer — never sends.
  /// → {lang, replies: [{kind, text, product_id?, name?, price?, in_stock?, mentioned?}]}
  Future<List<Map<String, dynamic>>> bizAgentQuickReplies(int threadId) async {
    final r = await getJson('/bizagent/threads/$threadId/quick-replies');
    return ((r['replies'] ?? const []) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> bizAgentMarkRead(int threadId) =>
      postJson('/bizagent/threads/$threadId/read');

  /// The owner confirms / cancels a DRAFT order the agent made from a
  /// customer's photo (stock changes only on confirm).
  Future<Map<String, dynamic>> bizAgentConfirmDraft(int orderId) =>
      postJson('/bizagent/orders/$orderId/confirm');

  Future<Map<String, dynamic>> bizAgentCancelDraft(int orderId) =>
      postJson('/bizagent/orders/$orderId/cancel');
}
