import 'dart:convert';
import 'package:flutter/material.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';

/// Local, user-controlled privacy + provenance layer for the Memory module.
///
/// The backend `MemoryItem` only carries title/category/detail/source. The
/// *advanced* memory module adds privacy controls (mark private, mark
/// sensitive, exclude from AI) and a "confirm before the AI learns" consent
/// queue. Those are stored **locally** (SharedPreferences via [Settings]) so
/// no API / model / state surface changes are needed — the data never leaves
/// the device and is keyed by the memory item's stable id. This keeps the
/// control fully in the user's hands (trust), and degrades honestly: if the
/// store is empty everything defaults to "shared with AI, not sensitive".
class MemPrivacy {
  MemPrivacy._();

  static const _kFlags = 'mem_privacy_flags_v1'; // id -> {p,s,x}
  static const _kConsent = 'mem_consent_queue_v1'; // pending AI-learned facts

  /// Stable per-item key — prefer the server id, fall back to the local id so
  /// a flag set while offline survives the eventual sync re-key.
  static String keyOf(MemoryItem m) =>
      m.serverId != null ? 'srv-${m.serverId}' : m.localId;

  // ---- privacy flags --------------------------------------------------------
  static Future<Map<String, MemFlags>> loadFlags() async {
    final raw = await Settings.getString(_kFlags);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(
          k, MemFlags.fromJson((v as Map).cast<String, dynamic>())));
    } catch (_) {
      return {}; // corrupt store → honest reset, never crash
    }
  }

  static Future<void> saveFlags(Map<String, MemFlags> flags) async {
    final out = flags.map((k, v) => MapEntry(k, v.toJson()));
    await Settings.setString(_kFlags, jsonEncode(out));
  }

  // ---- AI consent queue (confirm-before-learn) ------------------------------
  static Future<List<MemPending>> loadPending() async {
    final raw = await Settings.getString(_kConsent);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list) MemPending.fromJson((e as Map).cast<String, dynamic>())
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePending(List<MemPending> items) async {
    await Settings.setString(
        _kConsent, jsonEncode([for (final p in items) p.toJson()]));
  }

  /// Seed a couple of demo "AI wants to remember this" suggestions the first
  /// time the user opens the advanced view, so the consent flow is discoverable
  /// even before any live AI capture. Honest: tagged as suggestions, nothing is
  /// saved until the user confirms.
  static Future<void> seedIfFirstRun() async {
    final seeded = await Settings.getBool('mem_consent_seeded_v1', false);
    if (seeded) return;
    await Settings.setBool('mem_consent_seeded_v1', true);
    final existing = await loadPending();
    if (existing.isNotEmpty) return;
    await savePending([
      MemPending(
        id: 'seed-1',
        title: '',
        titleBn: '',
        category: 'preferences',
        detail: '',
        confidence: 0.82,
      ),
    ]);
  }
}

/// Per-item privacy flags. All default false = shared with AI, not sensitive.
class MemFlags {
  final bool private; // hidden from the default list unless "show private" on
  final bool sensitive; // extra-care badge (health, finance, etc.)
  final bool excludeFromAi; // never sent to the AI for personalization

  const MemFlags({
    this.private = false,
    this.sensitive = false,
    this.excludeFromAi = false,
  });

  bool get isDefault => !private && !sensitive && !excludeFromAi;

  MemFlags copyWith({bool? private, bool? sensitive, bool? excludeFromAi}) =>
      MemFlags(
        private: private ?? this.private,
        sensitive: sensitive ?? this.sensitive,
        excludeFromAi: excludeFromAi ?? this.excludeFromAi,
      );

  Map<String, dynamic> toJson() =>
      {'p': private, 's': sensitive, 'x': excludeFromAi};

  factory MemFlags.fromJson(Map<String, dynamic> j) => MemFlags(
        private: j['p'] == true,
        sensitive: j['s'] == true,
        excludeFromAi: j['x'] == true,
      );
}

/// A fact the AI proposes to remember — held until the user confirms.
/// title/titleBn carry the localized pair so the consent card shows in the
/// user's language without any Bangla literal in the .dart sources.
class MemPending {
  final String id;
  final String title; // en
  final String titleBn; // bn
  final String category;
  final String detail;
  final double confidence;

  const MemPending({
    required this.id,
    required this.title,
    required this.titleBn,
    this.category = '',
    this.detail = '',
    this.confidence = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'titleBn': titleBn,
        'category': category,
        'detail': detail,
        'confidence': confidence,
      };

  factory MemPending.fromJson(Map<String, dynamic> j) => MemPending(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        titleBn: (j['titleBn'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        detail: (j['detail'] ?? '') as String,
        confidence: ((j['confidence'] ?? 0) as num).toDouble(),
      );
}

// --------------------------------------------------------------------------
// Canonical categories — the six advanced buckets from SPEC §21. A free-text
// category from the backend is bucketed by matching known bn/en/Banglish words;
// anything unrecognised falls into "other". Each bucket has a stable id (used
// for storage + icon lookup) and a localized label resolved in the UI layer.
// --------------------------------------------------------------------------
enum MemCat { family, health, preferences, work, dates, other }

class MemCategories {
  MemCategories._();

  static const order = [
    MemCat.family,
    MemCat.health,
    MemCat.preferences,
    MemCat.work,
    MemCat.dates,
    MemCat.other,
  ];

  static IconData icon(MemCat c) {
    switch (c) {
      case MemCat.family:
        return Icons.family_restroom_rounded;
      case MemCat.health:
        return Icons.favorite_outline_rounded;
      case MemCat.preferences:
        return Icons.tune_rounded;
      case MemCat.work:
        return Icons.work_outline_rounded;
      case MemCat.dates:
        return Icons.event_rounded;
      case MemCat.other:
        return Icons.label_outline_rounded;
    }
  }

  static Color color(MemCat c) {
    switch (c) {
      case MemCat.family:
        return Brand.purple;
      case MemCat.health:
        return Brand.danger;
      case MemCat.preferences:
        return Brand.cyan;
      case MemCat.work:
        return Brand.blue;
      case MemCat.dates:
        return Brand.warning;
      case MemCat.other:
        return Colors.blueGrey;
    }
  }

  static const id = {
    MemCat.family: 'family',
    MemCat.health: 'health',
    MemCat.preferences: 'preferences',
    MemCat.work: 'work',
    MemCat.dates: 'dates',
    MemCat.other: 'other',
  };

  static MemCat fromId(String s) {
    for (final e in id.entries) {
      if (e.value == s) return e.key;
    }
    return MemCat.other;
  }

  /// ASCII/Banglish + id keywords for bucketing free-text categories. Pure
  /// ASCII — no Bangla literal (matching is case-insensitive, Bangla text is
  /// still bucketed via the explicit id written by the editor).
  static const _keywords = {
    MemCat.family: ['family', 'poribar', 'mom', 'dad', 'amma', 'abba', 'wife',
        'husband', 'son', 'daughter', 'child', 'baba', 'maa', 'relative'],
    MemCat.health: ['health', 'shasto', 'sastho', 'medicine', 'oshudh',
        'doctor', 'blood', 'pressure', 'sugar', 'diabetes', 'medical'],
    MemCat.preferences: ['preference', 'preferences', 'pochondo', 'like',
        'favourite', 'favorite', 'pref', 'habit'],
    MemCat.work: ['work', 'kaj', 'office', 'job', 'business', 'kaaj', 'meeting'],
    MemCat.dates: ['date', 'dates', 'birthday', 'jonmodin', 'anniversary',
        'tarikh', 'event', 'important date', 'din'],
  };

  /// Best-effort bucket for a backend free-text category string.
  static MemCat bucket(String category) {
    final c = category.trim().toLowerCase();
    if (c.isEmpty) return MemCat.other;
    for (final e in id.entries) {
      if (c == e.value) return e.key; // exact id match (what our editor writes)
    }
    // Whole-word match (tokenise) so short keywords don't match inside unrelated
    // words — e.g. "personal" must NOT match Family's "son", "mama" not "maa".
    // Multi-word keywords (e.g. "important date") still match as a phrase.
    final tokens = c
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    for (final e in _keywords.entries) {
      for (final kw in e.value) {
        final hit = kw.contains(' ') ? c.contains(kw) : tokens.contains(kw);
        if (hit) return e.key;
      }
    }
    return MemCat.other;
  }
}
