// pssec: Personal Secretary ↔ My Circle — open the person's end-to-end
// encrypted chat with a ready draft (meeting invite / follow-up reminder).
// The draft only fills the composer; the user reads it and taps Send.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../screens/circle_chat_screen.dart';
import '../state.dart';
import '../widgets/local_digits.dart' show ld;

/// "Tue 4 Nov, 4:00 PM" in the app language (Bangla digits in bn).
String psWhen(BuildContext context, DateTime at, {bool dateOnly = false}) {
  final loc = AppLocalizations.of(context).localeName;
  final f = dateOnly ? DateFormat('EEE d MMM', loc) : DateFormat('EEE d MMM, h:mm a', loc);
  return ld(context, f.format(at));
}

/// A My Circle person stored on a PS row: {"id": int, "name": String}.
List<Map<String, dynamic>> psCirclePeople(Object? raw) {
  final out = <Map<String, dynamic>>[];
  if (raw is! List) return out;
  for (final e in raw) {
    if (e is! Map) continue;
    final id = e['id'] is int ? e['id'] as int : int.tryParse('${e['id']}');
    if (id == null) continue;
    out.add({'id': id, 'name': '${e['name'] ?? ''}'.trim()});
  }
  return out;
}

/// Opens the chat with [circleId] pre-filled with [text]. If the person can't
/// be found in My Circle (removed, offline load), the text is copied and the
/// user is told honestly — never a silent no-op.
Future<void> psOpenChatWithDraft(BuildContext context,
    {required int circleId, required String name, required String text}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  Map<String, dynamic>? member;
  try {
    final m = await context.read<AppState>().api.getJson('/circle/members');
    final rows = (m['results'] ?? m['members'] ?? const []) as List;
    for (final r in rows) {
      if (r is Map && r['id'] == circleId) {
        member = r.cast<String, dynamic>();
        break;
      }
    }
  } catch (_) {
    member = null;
  }
  if (member == null) {
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(t.psNotInCircle(name))));
    return;
  }
  final identity = await IdentityVault.instance.get();
  await nav.push(MaterialPageRoute(
      builder: (_) =>
          CircleChatScreen(member: member!, identity: identity, initialText: text)));
}
