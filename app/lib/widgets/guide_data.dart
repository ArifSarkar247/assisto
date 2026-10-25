// Models + category metadata + an offline fallback for the ADVANCED
// Government / Service Guide module (feature 30, SPEC v2.1 §21).
//
// Source of truth for the CONTENT is the backend (core/logic/govt_guide.py),
// which returns a bilingual, fully-localised payload via api.guides(). The
// screen caches that payload offline (SharedPreferences JSON) so the guide
// works with no network. This file holds:
//   * the parsed model (GuideService / GuideCategory),
//   * per-category icon + tint (UI chrome, not copy),
//   * a tiny English-only offline fallback so a fresh install that has never
//     reached the server still shows something honest (banner says so).
//
// No Bangla literals live in any .dart (constraint). The fallback below is
// English-only DATA; the real bn text arrives from the server/cache. Every
// fee carries verifyFee=true and a source — we never present a fee as final.

import 'package:flutter/material.dart';

/// One step-by-step government/public service guide.
class GuideService {
  final String key;
  final String category;
  final String name;
  final String portal; // short host, shown as the source
  final String url; // official link the app opens (may be empty)
  final List<String> steps;
  final List<String> docs; // required-documents checklist
  final String fee;
  final bool verifyFee; // always true -> UI shows "verify on portal"
  final String office; // where / which office
  final String time; // typical processing time
  final bool verifyTime;
  final List<String> mistakes; // common mistakes
  final String source; // "Source: <portal>"
  final String disclaimer;

  const GuideService({
    required this.key,
    required this.category,
    required this.name,
    required this.portal,
    required this.url,
    required this.steps,
    required this.docs,
    required this.fee,
    required this.verifyFee,
    required this.office,
    required this.time,
    required this.verifyTime,
    required this.mistakes,
    required this.source,
    required this.disclaimer,
  });

  factory GuideService.fromJson(Map<String, dynamic> j) => GuideService(
        key: (j['key'] ?? '').toString(),
        category: (j['category'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        portal: (j['portal'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        steps: _strList(j['steps']),
        docs: _strList(j['docs']),
        fee: (j['fee'] ?? '').toString(),
        verifyFee: j['fee_verify'] != false, // default true
        office: (j['office'] ?? '').toString(),
        time: (j['time'] ?? '').toString(),
        verifyTime: j['time_verify'] != false,
        mistakes: _strList(j['mistakes']),
        source: (j['source'] ?? '').toString(),
        disclaimer: (j['disclaimer'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'category': category,
        'name': name,
        'portal': portal,
        'url': url,
        'steps': steps,
        'docs': docs,
        'fee': fee,
        'fee_verify': verifyFee,
        'office': office,
        'time': time,
        'time_verify': verifyTime,
        'mistakes': mistakes,
        'source': source,
        'disclaimer': disclaimer,
      };
}

/// A named category grouping of services (localised name from the server).
class GuideCategory {
  final String key;
  final String name;
  const GuideCategory(this.key, this.name);

  factory GuideCategory.fromJson(Map<String, dynamic> j) =>
      GuideCategory((j['key'] ?? '').toString(), (j['name'] ?? '').toString());

  Map<String, dynamic> toJson() => {'key': key, 'name': name};
}

/// Full parsed guide payload (what api.guides() returns, advanced shape).
class GuideData {
  final String version;
  final List<GuideCategory> categories;
  final List<GuideService> services;
  final String disclaimer;
  const GuideData({
    required this.version,
    required this.categories,
    required this.services,
    required this.disclaimer,
  });

  factory GuideData.fromJson(Map<String, dynamic> j) => GuideData(
        version: (j['version'] ?? '2.1').toString(),
        categories: ((j['categories'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(GuideCategory.fromJson)
            .toList(),
        services: ((j['services'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(GuideService.fromJson)
            .toList(),
        disclaimer: (j['disclaimer'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'categories': categories.map((c) => c.toJson()).toList(),
        'services': services.map((s) => s.toJson()).toList(),
        'disclaimer': disclaimer,
      };

  bool get isEmpty => services.isEmpty;
}

List<String> _strList(dynamic v) =>
    (v is List) ? v.map((e) => e.toString()).toList() : const [];

// ---------------------------------------------------------------------------
// Per-category icon + tint. The label comes from the server payload
// (GuideCategory.name), so this map holds only UI chrome keyed by category key.
// ---------------------------------------------------------------------------
class GuideCatMeta {
  final IconData icon;
  final Color tint;
  const GuideCatMeta(this.icon, this.tint);
}

const Map<String, GuideCatMeta> kGuideCatMeta = {
  'identity': GuideCatMeta(Icons.badge_rounded, Color(0xFF3B6EF6)),
  'travel': GuideCatMeta(Icons.flight_takeoff_rounded, Color(0xFF9B4DF0)),
  'driving': GuideCatMeta(Icons.directions_car_rounded, Color(0xFF2347D9)),
  'tax': GuideCatMeta(Icons.receipt_long_rounded, Color(0xFF2E9E6B)),
  'land': GuideCatMeta(Icons.landscape_rounded, Color(0xFFE0A500)),
  'business': GuideCatMeta(Icons.storefront_rounded, Color(0xFFE0485A)),
  'utility': GuideCatMeta(Icons.bolt_rounded, Color(0xFFE0A500)),
  'police': GuideCatMeta(Icons.verified_user_rounded, Color(0xFF2347D9)),
};

const GuideCatMeta _kDefaultCatMeta =
    GuideCatMeta(Icons.description_rounded, Color(0xFF3B6EF6));

GuideCatMeta guideCatMeta(String key) => kGuideCatMeta[key] ?? _kDefaultCatMeta;

/// Per-service icon (chrome only; falls back to the category icon).
const Map<String, IconData> kGuideServiceIcon = {
  'nid': Icons.badge_rounded,
  'epassport': Icons.book_rounded,
  'birth': Icons.child_care_rounded,
  'driving': Icons.directions_car_rounded,
  'tin': Icons.receipt_long_rounded,
  'porcha': Icons.landscape_rounded,
  'trade_license': Icons.storefront_rounded,
  'electricity': Icons.bolt_rounded,
  'water_gas': Icons.water_drop_rounded,
  'police_clearance': Icons.verified_user_rounded,
  'brta_vehicle': Icons.directions_car_filled_rounded,
};

IconData guideServiceIcon(GuideService s) =>
    kGuideServiceIcon[s.key] ?? guideCatMeta(s.category).icon;

// ---------------------------------------------------------------------------
// Minimal ENGLISH-ONLY offline fallback (DATA, no UI copy, no Bangla).
// Used only on a fresh install that has never successfully reached the server
// AND is currently offline. The banner makes clear it's a cached/sample fallback
// and tells the user to open the official portal. Fees stay verify-on-portal.
// ---------------------------------------------------------------------------
const List<GuideCategory> _kFallbackCategories = [
  GuideCategory('identity', 'Identity & citizenship'),
  GuideCategory('travel', 'Travel & passport'),
  GuideCategory('driving', 'Vehicles & licence'),
  GuideCategory('tax', 'Tax & revenue'),
  GuideCategory('land', 'Land & property'),
  GuideCategory('business', 'Business & trade'),
  GuideCategory('utility', 'Utility connections'),
  GuideCategory('police', 'Police & clearance'),
];

GuideService _fb(String key, String cat, String name, String portal, String url,
        List<String> steps, List<String> docs) =>
    GuideService(
      key: key,
      category: cat,
      name: name,
      portal: portal,
      url: url,
      steps: steps,
      docs: docs,
      fee: 'Fees vary — verify on the official portal.',
      verifyFee: true,
      office: 'See the official portal for the responsible office.',
      time: 'Processing time varies — verify on the official portal.',
      verifyTime: true,
      mistakes: const [
        'Details not matching the supporting documents',
        'Missing a required document or payment receipt',
      ],
      source: 'Source: $portal',
      disclaimer:
          'Cached sample — fees, timelines and rules can change. Verify on the official portal before applying.',
    );

final GuideData kGuideFallback = GuideData(
  version: '2.1',
  categories: _kFallbackCategories,
  disclaimer:
      'Cached sample — fees, timelines and rules can change. Verify on the official portal before applying.',
  services: [
    _fb('nid', 'identity', 'National ID (NID)', 'services.nidw.gov.bd',
        'https://services.nidw.gov.bd', const [
      'Register and log in on the portal',
      'Fill the form with your details',
      'Upload the required documents',
      'Submit and track your application',
    ], const [
      'Birth registration certificate',
      'Proof of address (utility bill)',
      'Passport-size photo',
    ]),
    _fb('epassport', 'travel', 'e-Passport', 'epassport.gov.bd',
        'https://www.epassport.gov.bd', const [
      'Apply online on the portal',
      'Choose pages and validity',
      'Pay the fee and book a biometric appointment',
      'Track delivery after police verification',
    ], const [
      'Printed application summary',
      'National ID (NID)',
      'Old passport (if renewing)',
    ]),
    _fb('birth', 'identity', 'Birth registration', 'bdris.gov.bd',
        'https://bdris.gov.bd', const [
      'Fill the application on the BDRIS portal',
      'Pick the office by address of birth',
      'Upload supporting documents',
      'Collect the certificate after approval',
    ], const [
      'Hospital/EPI vaccination card',
      "Parent's NID",
      'Proof of address',
    ]),
    _fb('driving', 'driving', 'Driving licence', 'bsp.brta.gov.bd',
        'https://bsp.brta.gov.bd', const [
      'Create an account on BRTA BSP',
      "Apply for a learner's licence",
      'Submit fee and a medical certificate',
      'Pass the tests and collect the smart card',
    ], const [
      'National ID (NID)',
      'Medical certificate with blood group',
      'Passport-size photo',
    ]),
    _fb('tin', 'tax', 'TIN & e-Return', 'etaxnbr.gov.bd',
        'https://etaxnbr.gov.bd', const [
      'Register on eTIN to get a TIN',
      'Log in to your e-Return account',
      'Enter income and assets',
      'Submit and save the acknowledgement',
    ], const [
      'National ID (NID)',
      'Proof of income',
      'Bank statement',
    ]),
    _fb('police_clearance', 'police', 'Police Clearance Certificate',
        'pcc.police.gov.bd', 'https://pcc.police.gov.bd', const [
      'Apply on the Police Clearance portal',
      'Enter permanent address and purpose',
      'Pay the fee by challan',
      'Collect after verification',
    ], const [
      'Valid passport',
      'National ID (NID)',
      'Proof of permanent address',
    ]),
  ],
);
