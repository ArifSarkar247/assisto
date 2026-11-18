// sos-numbers (SAFETY P0, lead 18 Nov): on a new or reinstalled phone the
// family's emergency numbers lived only on the server, so the SOS call / SMS
// steps had nobody until the user opened the emergency card screen. Now the
// card is fetched at app start and after every sign-in and kept on the phone
// (the same copy the card screen and the Emergency page read), so SOS works
// offline right away. Sign-out clears it — the next account never texts the
// previous account's family.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../state.dart' show Settings;

enum SosNumbersState { unknown, syncing, ok, failed }

class SosNumbersSync {
  SosNumbersSync._();

  /// The phone copy of the emergency card (same key as the card screen).
  static const cacheKey = 'emergency_card_cache';

  /// Set by the card screen when an edit could not reach the server yet.
  static const dirtyKey = 'emergency_card_dirty';

  /// Last result, for the Emergency page's honest line.
  static final ValueNotifier<SosNumbersState> state =
      ValueNotifier(SosNumbersState.unknown);

  static Future<void>? _running;

  /// Fetch the server card and keep it on the phone. Never throws; one run
  /// at a time. Offline edits made on this phone are sent first (the phone
  /// copy is newer), never overwritten.
  static Future<void> sync(ApiClient api) => _running ??= _sync(api).whenComplete(() {
        _running = null;
      });

  static Future<void> _sync(ApiClient api) async {
    if (api.token == null) return;
    state.value = SosNumbersState.syncing;
    try {
      final cached = await Settings.getString(cacheKey);
      if (cached != null && cached.isNotEmpty && await Settings.getString(dirtyKey) == '1') {
        final body = jsonDecode(cached);
        if (body is Map<String, dynamic>) {
          await api.putEmergency(body).timeout(const Duration(seconds: 15));
          await Settings.setString(dirtyKey, '');
        }
      }
      final card = await api.getEmergency().timeout(const Duration(seconds: 15));
      // a phone edit made while we were fetching wins (the card screen syncs it)
      if (await Settings.getString(dirtyKey) == '1') {
        state.value = SosNumbersState.ok;
        return;
      }
      await Settings.setString(cacheKey, jsonEncode(card));
      state.value = SosNumbersState.ok;
    } catch (_) {
      // offline / server down: keep whatever copy the phone has
      state.value = SosNumbersState.failed;
    }
  }

  /// Numbers saved on this phone (name + phone), in card order.
  static Future<List<Map<String, String>>> cachedContacts() async {
    try {
      final raw = await Settings.getString(cacheKey);
      if (raw == null || raw.isEmpty) return const [];
      final d = jsonDecode(raw);
      if (d is! Map) return const [];
      return [
        for (final c in (d['contacts'] as List? ?? const []))
          if (c is Map && '${c['phone'] ?? ''}'.trim().isNotEmpty)
            {'name': '${c['name'] ?? ''}', 'phone': '${c['phone']}'.trim()}
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Sign-out: this account's family numbers leave the phone.
  static Future<void> clear() async {
    await Settings.setString(cacheKey, '');
    await Settings.setString(dirtyKey, '');
    state.value = SosNumbersState.unknown;
  }

  @visibleForTesting
  static void resetForTest() {
    _running = null;
    state.value = SosNumbersState.unknown;
  }
}
