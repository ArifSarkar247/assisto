// f2-design guards (owner order F, part 2).
//  1. No NEW hard-coded `Color(0x…)` outside lib/theme.dart. The literals that
//     exist today are allowlisted per file (call/camera canvases, the chat
//     theme + wallpaper palettes, image watermarks, map/route canvases…); a
//     file may only go DOWN. When you remove literals, lower its count here.
//     New colours belong in theme.dart (Brand / AssistoTokens / ColorScheme).
//  2. The screens polished in f2 (AI chat, Photo Studio, Settings, Business,
//     CRM, Shop Box, money, reminders) carry no `fontSize:` literal — they
//     use the text theme / AType scale.
//  3. AType is the text theme's metrics (one scale, no drift).
import 'dart:io';

import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Existing `Color(0x` literals per file (comments ignored), 2026-10-24.
const _colorAllow = <String, int>{
  'lib/growth/branded_share.dart': 5,
  'lib/growth/invite_screen.dart': 2,
  'lib/messaging/call_events.dart': 2,
  'lib/messaging/chat_decor/chat_themes.dart': 107,
  'lib/messaging/chat_decor/decor_sheets.dart': 2,
  'lib/messaging/msg_ticks.dart': 10,
  'lib/photo_studio/ps_export.dart': 3,
  'lib/screens/admin/owner_pnl_screen.dart': 1,
  'lib/screens/always_on_protection_screen.dart': 1,
  'lib/screens/circle_group_info_screen.dart': 1,
  'lib/screens/circle_status_composer_screen.dart': 5,
  'lib/screens/dictionary_screen.dart': 2,
  'lib/screens/elderly_home_screen.dart': 6,
  'lib/screens/farmer_mode_screen.dart': 24,
  'lib/screens/health_timeline_screen.dart': 2,
  'lib/screens/journey_fake_call_screen.dart': 1,
  'lib/screens/journey_live_screen.dart': 1,
  'lib/screens/journey_sos_screen.dart': 6,
  'lib/screens/lost_stolen_screen.dart': 1,
  'lib/screens/medicine_db_screen.dart': 2,
  'lib/screens/meetings_screen.dart': 4,
  'lib/screens/photo_studio_screen.dart': 2,
  'lib/screens/safety_screen.dart': 2,
  'lib/screens/security_checkup_screen.dart': 1,
  'lib/screens/trust_page_screen.dart': 2,
  'lib/screens/vault_screen.dart': 1,
  'lib/screens/voice_assistant_screen.dart': 4,
  'lib/screens/voice_assistant_settings_screen.dart': 2,
  'lib/vehicle/route_canvas.dart': 4,
  'lib/voice/va_confirm_sheet.dart': 1,
  'lib/widgets/chat_menu_pickers.dart': 6,
  'lib/widgets/circle_extras_wallpaper.dart': 8,
  'lib/widgets/contacts_sheets.dart': 1,
  'lib/widgets/crm_company_widgets.dart': 2,
  'lib/widgets/crm_leaderboard_list.dart': 3,
  'lib/widgets/dict_extras.dart': 2,
  'lib/widgets/disaster_model.dart': 2,
  'lib/widgets/disaster_warning_card.dart': 1,
  'lib/widgets/fam_card_section.dart': 2,
  'lib/widgets/founder_badge.dart': 2,
  'lib/widgets/guide_data.dart': 9,
  'lib/widgets/inbox_item_card.dart': 4,
  'lib/widgets/meddb_drug_card.dart': 2,
  'lib/widgets/nearby_data.dart': 10,
  'lib/widgets/ref_leaderboard.dart': 3,
  'lib/widgets/safety_checkin_card.dart': 1,
  'lib/widgets/sos_button.dart': 1,
};

/// Files polished in f2: no `fontSize:` literal (except image painting).
const _f2Screens = <String>[
  'lib/screens/ai_chat_screen.dart',
  'lib/screens/agent_thread_screen.dart',
  'lib/screens/photo_studio_screen.dart',
  'lib/photo_studio/',
  'lib/screens/settings_screen.dart',
  'lib/screens/business/',
  'lib/screens/crm/',
  'lib/screens/crm_contacts_screen.dart',
  'lib/screens/shop_',
  'lib/screens/money_',
  'lib/screens/reminders',
  // f3-design: My Circle + call screens (circle_chat / circle_group_chat are
  // type-scale clean too but not guarded yet — another branch is adding
  // attach options there; guard them once that has merged).
  'lib/calls/',
  'lib/push/incoming_call_screen.dart',
  'lib/screens/circle_call_screen.dart',
  'lib/screens/circle_screen.dart',
  'lib/screens/ring_checklist_screen.dart',
  'lib/screens/messenger/messenger_home_screen.dart',
  'lib/screens/messenger/contact_info_screen.dart',
  'lib/screens/messenger/m3_',
  'lib/screens/messenger/connection_requests_screen.dart',
  'lib/widgets/msgr_hub_chat_list.dart',
];

/// `fontSize: <expr>` allowed here: the export watermark is painted onto the
/// image itself and scales with the image, not with the UI type scale; the
/// call avatar's initial is sized from the avatar radius.
const _fontSizeAllow = <String>{
  'lib/photo_studio/ps_export.dart',
  'lib/calls/call_avatar.dart',
};

/// Source lines with `//` comments removed (good enough for these guards:
/// a `//` inside a string only hides the rest of that line).
Iterable<String> _code(File f) => f
    .readAsLinesSync()
    .map((l) => l.trimLeft().startsWith('//') ? '' : l.split('//').first);

List<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

String _rel(File f) => f.path.replaceAll(r'\', '/');

void main() {
  test('no new Color(0x…) literal outside lib/theme.dart', () {
    final colour = RegExp(r'\bColor\(0x');
    final over = <String>[];
    for (final f in _dartFiles()) {
      final p = _rel(f);
      if (p == 'lib/theme.dart' || p.startsWith('lib/l10n/')) continue;
      final n = _code(f).map((l) => colour.allMatches(l).length).fold(0, (a, b) => a + b);
      final allowed = _colorAllow[p] ?? 0;
      if (n > allowed) over.add('$p: $n Color(0x…) literal(s), allowed $allowed');
    }
    expect(over, isEmpty,
        reason: 'Use Theme.of(context).colorScheme / AssistoTokens / Brand '
            '(lib/theme.dart) instead of a new hard-coded colour:\n${over.join('\n')}');
  });

  test('f2 screens use the type scale (no fontSize literal)', () {
    final fs = RegExp(r'\bfontSize\s*:');
    final bad = <String>[];
    for (final f in _dartFiles()) {
      final p = _rel(f);
      if (!_f2Screens.any(p.startsWith) || _fontSizeAllow.contains(p)) continue;
      var i = 0;
      for (final l in _code(f)) {
        i++;
        if (fs.hasMatch(l)) bad.add('$p:$i: ${l.trim()}');
      }
    }
    expect(bad, isEmpty,
        reason: 'Use Theme.of(context).textTheme.* or AType.* instead:\n${bad.join('\n')}');
  });

  test('AType == text theme metrics (one type scale)', () {
    for (final theme in [AssistoTheme.light, AssistoTheme.dark]) {
      final t = theme.textTheme;
      final pairs = <(TextStyle?, TextStyle)>[
        (t.displayLarge, AType.displayLarge),
        (t.displayMedium, AType.displayMedium),
        (t.displaySmall, AType.displaySmall),
        (t.headlineLarge, AType.headlineLarge),
        (t.headlineMedium, AType.headlineMedium),
        (t.headlineSmall, AType.headlineSmall),
        (t.titleLarge, AType.titleLarge),
        (t.titleMedium, AType.titleMedium),
        (t.titleSmall, AType.titleSmall),
        (t.bodyLarge, AType.bodyLarge),
        (t.bodyMedium, AType.bodyMedium),
        (t.bodySmall, AType.bodySmall),
        (t.labelLarge, AType.labelLarge),
        (t.labelMedium, AType.labelMedium),
        (t.labelSmall, AType.labelSmall),
      ];
      for (final (role, m) in pairs) {
        expect(role?.fontSize, m.fontSize);
        expect(role?.height, m.height);
        expect(role?.letterSpacing, m.letterSpacing);
        expect(role?.leadingDistribution, TextLeadingDistribution.even);
        // AType carries no colour / weight: it inherits like a bare TextStyle.
        expect(m.color, isNull);
        expect(m.fontWeight, isNull);
        expect(m.inherit, isTrue);
      }
    }
  });
}
