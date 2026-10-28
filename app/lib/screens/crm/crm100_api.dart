import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../state.dart';

/// crm100 — the client for the one-customer history page, the merged
/// customer list, shop price quotes and "send from CRM". All on the
/// existing generic ApiClient (getJson / postJson); every path lives under
/// `/crm/` (backend crm/views_crm100.py).
class Crm100Api {
  final ApiClient _c;
  Crm100Api(this._c);

  static Crm100Api of(BuildContext ctx) => Crm100Api(ctx.read<AppState>().api);

  static String _q(Map<String, Object?> p) {
    final parts = <String>[];
    p.forEach((k, v) {
      if (v == null) return;
      final s = '$v';
      if (s.isEmpty) return;
      parts.add('$k=${Uri.encodeQueryComponent(s)}');
    });
    return parts.join('&');
  }

  /// Merged customer list (khata + till + orders + AI chats + CRM leads).
  Future<Map<String, dynamic>> customers(
          {int? business, String q = '', String? only, int offset = 0, int limit = 50}) =>
      _c.getJson('/crm/customers/?${_q({
            'business': business,
            'q': q,
            'only': only,
            'offset': offset,
            'limit': limit
          })}');

  /// One customer's whole history. [target] carries exactly one of
  /// phone / party / lead / customer / order.
  Future<Map<String, dynamic>> history(CustomerTarget target,
          {int? business, String? before, String? kinds, int limit = 40}) =>
      _c.getJson('/crm/customers/history/?${_q({
            ...target.query,
            'business': business,
            'before': before,
            'kinds': kinds,
            'limit': limit
          })}');

  // ---- shop quotes ----
  Future<Map<String, dynamic>> quotes({int? business, String? phone}) =>
      _c.getJson('/crm/shop-quotes/?${_q({'business': business, 'phone': phone})}');
  Future<Map<String, dynamic>> catalog({int? business, String q = ''}) =>
      _c.getJson('/crm/shop-quotes/catalog/?${_q({'business': business, 'q': q})}');
  Future<Map<String, dynamic>> createQuote(Map<String, dynamic> body) =>
      _c.postJson('/crm/shop-quotes/', body);
  Future<Map<String, dynamic>> extendQuote(int id, int days, {int? business}) =>
      _c.postJson('/crm/shop-quotes/$id/extend/?${_q({'business': business})}', {'days': days});
  Future<Map<String, dynamic>> revokeQuote(int id, {int? business}) =>
      _c.postJson('/crm/shop-quotes/$id/revoke/?${_q({'business': business})}');

  // ---- send ----
  Future<Map<String, dynamic>> sendPreview(CustomerTarget target, String text,
          {int? business, String? lang}) =>
      _c.postJson('/crm/send/preview', {
        ...target.body,
        'text': text,
        if (business != null) 'business': business,
        if (lang != null) 'lang': lang,
      });
  Future<Map<String, dynamic>> sendLog(CustomerTarget target, String channel, String text,
          {int? business, String purpose = 'message', int? lead, String? bulkId}) =>
      _c.postJson('/crm/send/log', {
        ...target.body,
        'channel': channel,
        'text': text,
        'purpose': purpose,
        if (business != null) 'business': business,
        if (lead != null) 'lead': lead,
        if (bulkId != null) 'bulk_id': bulkId,
      });
  Future<Map<String, dynamic>> sendSms(CustomerTarget target, String text, int credits,
          {int? business, String? lang, int? lead, String? bulkId}) =>
      _c.postJson('/crm/send/sms', {
        ...target.body,
        'text': text,
        'credits': credits,
        if (business != null) 'business': business,
        if (lang != null) 'lang': lang,
        if (lead != null) 'lead': lead,
        if (bulkId != null) 'bulk_id': bulkId,
      });
  Future<Map<String, dynamic>> sendBulk(List<CustomerTarget> targets, String text,
          {int? business, String? lang}) =>
      _c.postJson('/crm/send/bulk', {
        'targets': [for (final t in targets) t.body],
        'text': text,
        if (business != null) 'business': business,
        if (lang != null) 'lang': lang,
      });
}

/// Who a history / send call is about. One field is set.
class CustomerTarget {
  final String? phone;
  final int? party;
  final int? lead;
  final int? customer;
  final int? order;
  const CustomerTarget({this.phone, this.party, this.lead, this.customer, this.order});

  factory CustomerTarget.fromRow(Map<String, dynamic> r) {
    final key = '${r['phone_key'] ?? ''}';
    if (key.isNotEmpty) return CustomerTarget(phone: key);
    final p = (r['party_id'] as num?)?.toInt();
    if (p != null) return CustomerTarget(party: p);
    return CustomerTarget(lead: (r['lead_id'] as num?)?.toInt());
  }

  Map<String, Object?> get query => {
        'phone': phone,
        'party': party,
        'lead': lead,
        'customer': customer,
        'order': order,
      };

  Map<String, dynamic> get body => {
        if (phone != null) 'phone': phone,
        if (party != null) 'party': party,
        if (lead != null) 'lead': lead,
        if (customer != null) 'customer': customer,
        if (order != null) 'order': order,
      };

  /// A stable key for the offline copy.
  String get cacheKey => phone != null
      ? 'p:$phone'
      : party != null
          ? 'k:$party'
          : lead != null
              ? 'l:$lead'
              : customer != null
                  ? 'c:$customer'
                  : 'o:$order';
}

/// The last history page we saw for a customer, kept on the phone so the
/// page still opens without internet (clearly marked as a saved copy).
/// At most [_max] customers; the oldest is dropped first.
class CustomerHistoryCache {
  static const _k = 'crm100_history_v1';
  static const _max = 40;

  static Future<Map<String, dynamic>?> read(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_k);
      if (raw == null) return null;
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final v = m[key];
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null; // a corrupt cache is treated as no cache
    }
  }

  static Future<void> write(String key, Map<String, dynamic> data) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_k);
      final m = raw == null
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
      m.remove(key);
      m[key] = {...data, 'saved_at': DateTime.now().toIso8601String()};
      while (m.length > _max) {
        m.remove(m.keys.first);
      }
      await sp.setString(_k, jsonEncode(m));
    } catch (_) {/* best-effort: a convenience copy only */}
  }
}
