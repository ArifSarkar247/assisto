import '../api.dart';

/// f1-founders: in-app feedback endpoints (backend core/views_f1_feedback.py).
extension FeedbackApi on ApiClient {
  /// POST /feedback — note + category + optional base64 screenshot + the
  /// app/device/language/screen details the user saw before sending.
  /// 201 -> the created report; 4xx/5xx -> [ApiException] (status kept, so
  /// the sheet can tell "rate limited" from "offline/server").
  Future<Map<String, dynamic>> sendFeedback(Map<String, dynamic> body) =>
      postJson('/feedback', body);

  /// GET /feedback — the signed-in user's own reports (newest first).
  Future<Map<String, dynamic>> myFeedback() => getJson('/feedback');
}
