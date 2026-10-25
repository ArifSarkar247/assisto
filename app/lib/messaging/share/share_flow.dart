import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/contacts_source.dart';
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/c1_contacts_widgets.dart' show C1Disclosure;
import '../../widgets/circle_attach_sheet.dart' show CircleAttachKind;
import '../../widgets/contacts_match_widgets.dart' show showCmPrivacyExplainer;
import '../date_separators.dart' show fmtDate, localDigits;
import 'contact_card.dart';
import 'live_location.dart';
import 'location_card.dart';
import 'share_payload.dart';
import 'share_send.dart';

/// mc-media2 — the chat side of sharing a location / live location / contact
/// card (1:1 and group). Pick → preview → seal on this phone → send.

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

String _lang(BuildContext c) => Localizations.localeOf(c).languageCode;

// ---------------------------------------------------------------- live wiring
/// One position, WITHOUT ever prompting (the live ticker): null when the
/// permission is not granted, GPS is off or no fix came in time.
Future<LocationShare?> readPositionQuiet() async {
  try {
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
    if (!LocationShare.validLatLng(p.latitude, p.longitude)) return null;
    return LocationShare(
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy,
        at: DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    return null;
  }
}

/// Lazy: called when a chat opens or a live share starts — never at launch.
void wireLiveLocation(ApiClient api) {
  LiveLocation.instance.configure(
    positions: readPositionQuiet,
    transport: (s, plaintext) => pushLiveUpdate(api,
        chatKind: s.chatKind,
        chatId: s.chatId,
        messageId: s.messageId,
        plaintext: plaintext),
  );
  unawaited(LiveLocation.instance.restore());
}

// ---------------------------------------------------------------- location
/// The existing location permission flow, with a short in-app explanation
/// before the OS prompt. true = may read the location now.
Future<bool> ensureLocationPermission(BuildContext context) async {
  final t = AppLocalizations.of(context);
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!context.mounted) return false;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(t.mc2GpsOff),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1PermNotNow)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(t.mc2TurnOnLocation)),
          ],
        ),
      );
      if (go == true) await Geolocator.openLocationSettings();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      if (!context.mounted) return false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('mc2-loc-perm'),
          icon: const Icon(Icons.location_on_rounded),
          title: Text(t.mc2PermLocTitle),
          content: Text(t.mc2PermLocBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1PermNotNow)),
            FilledButton(
                key: const Key('mc2-loc-perm-continue'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.md1PermContinue)),
          ],
        ),
      );
      if (ok != true) return false;
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      if (!context.mounted) return false;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(t.mc2PermLocDenied),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1PermNotNow)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(t.md1OpenSettings)),
          ],
        ),
      );
      if (go == true) await Geolocator.openAppSettings();
      return false;
    }
    return true;
  } catch (e) {
    reportNonFatal('mc2_loc_perm', e);
    return false;
  }
}

/// One fresh fix with a "Finding your location…" dialog (last known as a
/// fallback); null = none (an honest message is shown).
Future<LocationShare?> _findMe(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(t.mc2Finding)),
        ]),
      ),
    ),
  ).whenComplete(() => open = false));
  LocationShare? out;
  try {
    Position? p;
    try {
      p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
    } catch (_) {
      p = await Geolocator.getLastKnownPosition();
    }
    if (p != null && LocationShare.validLatLng(p.latitude, p.longitude)) {
      out = LocationShare(
          lat: p.latitude,
          lng: p.longitude,
          accuracy: p.accuracy,
          at: DateTime.now().millisecondsSinceEpoch);
    }
  } catch (e) {
    reportNonFatal('mc2_loc_fix', e);
  }
  if (open) nav.pop();
  if (out == null && context.mounted) _toast(context, t.mc2NoFix);
  return out;
}

/// The live duration chooser with the honest foreground-only note.
Future<String?> pickLiveDuration(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Text(t.mc2LiveTitle, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
          child: Text(t.mc2ForegroundNote,
              key: const Key('mc2-live-note'),
              style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ),
        for (final e in {'15m': t.circleLive15m, '1h': t.circleLive1h, '8h': t.circleLive8h}.entries)
          ListTile(
            key: Key('mc2-live-${e.key}'),
            leading: const Icon(Icons.timer_rounded),
            title: Text(e.value),
            onTap: () => Navigator.pop(ctx, e.key),
          ),
      ]),
    ),
  );
}

class _LocChoice {
  final bool live;
  final String label;
  const _LocChoice(this.live, this.label);
}

class _LocationPreview extends StatefulWidget {
  final LocationShare share;
  const _LocationPreview({required this.share});
  @override
  State<_LocationPreview> createState() => _LocationPreviewState();
}

class _LocationPreviewState extends State<_LocationPreview> {
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: Gap.lg,
            right: Gap.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Center(child: LocationCard(share: widget.share, mine: false, fg: scheme.onSurface)),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const Key('mc2-loc-label'),
              controller: _label,
              maxLength: 80,
              decoration: InputDecoration(
                  hintText: t.mc2PlaceHint, border: const OutlineInputBorder()),
            ),
            FilledButton.icon(
              key: const Key('mc2-loc-send'),
              onPressed: () => Navigator.pop(context, _LocChoice(false, _label.text.trim())),
              icon: const Icon(Icons.send_rounded),
              label: Text(t.mc2SendLocation),
            ),
            const SizedBox(height: Gap.xs),
            OutlinedButton.icon(
              key: const Key('mc2-loc-live'),
              onPressed: () => Navigator.pop(context, _LocChoice(true, _label.text.trim())),
              icon: const Icon(Icons.my_location_rounded),
              label: Text(t.mc2ShareLive),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Attach → Location (preview with "Send" / "Share live") or Attach → Live
/// location ([live]: straight to the durations). Returns the server message
/// id, or null (cancelled / an honest message shown).
Future<String?> shareLocationFlow(BuildContext context,
    {required String chatKind, required int chatId, bool live = false}) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  if (!await ensureLocationPermission(context) || !context.mounted) return null;
  final fix = await _findMe(context);
  if (fix == null || !context.mounted) return null;
  var label = '';
  var wantLive = live;
  if (!live) {
    final c = await showModalBottomSheet<_LocChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LocationPreview(share: fix),
    );
    if (c == null || !context.mounted) return null;
    label = c.label;
    wantLive = c.live;
  }
  var share = LocationShare(
      lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy, label: label, at: fix.at);
  final lang = _lang(context);
  String fallback = t.mc2FallbackLocation(share.webUri.toString());
  if (wantLive) {
    final d = await pickLiveDuration(context);
    if (d == null || !context.mounted) return null;
    final until = DateTime.now().add(Duration(minutes: kLiveDurationsMin[d] ?? 15));
    share = LocationShare(
        lat: share.lat,
        lng: share.lng,
        accuracy: share.accuracy,
        label: label,
        at: share.at,
        live: true,
        until: until.millisecondsSinceEpoch);
    fallback = t.mc2FallbackLive(fmtDate('h:mm a', until, lang), share.webUri.toString());
  }
  try {
    final id = await sendShare(api,
        chatKind: chatKind,
        chatId: chatId,
        contentType: 'location',
        plaintext: encodeLocation(share, fallback));
    if (wantLive && id.isNotEmpty) {
      wireLiveLocation(api);
      await LiveLocation.instance.start(LiveSession(
          chatKind: chatKind, chatId: chatId, messageId: id, fallback: fallback, last: share));
    }
    return id;
  } catch (e) {
    reportNonFatal('mc2_loc_send', e);
    if (context.mounted) _toast(context, t.mc2SendFailed);
    return null;
  }
}

// ---------------------------------------------------------------- contact
const _kContactsConsent = 'c1_contacts_consent_v1'; // same as the contacts screen

Future<ContactShare?> _pickPhoneContact(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final src = ContactsSources.create();
  if (!src.available) {
    _toast(context, t.mc2ContactsCantRead);
    return null;
  }
  var consent = false;
  try {
    consent = (await SharedPreferences.getInstance()).getBool(_kContactsConsent) ?? false;
  } catch (_) {}
  var st = await src.status();
  if (!consent || st != ContactsPermission.granted) {
    if (!context.mounted) return null;
    final allow = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text(t.mc2ContactFromPhone)),
        body: C1Disclosure(
          onAllow: () => Navigator.pop(ctx, true),
          onDeny: () => Navigator.pop(ctx, false),
          onPrivacy: () => showCmPrivacyExplainer(ctx),
        ),
      ),
    ));
    if (allow != true) return null;
    try {
      await (await SharedPreferences.getInstance()).setBool(_kContactsConsent, true);
    } catch (_) {}
    st = await src.request();
  }
  if (st != ContactsPermission.granted) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(st == ContactsPermission.unavailable ? t.mc2ContactsCantRead : t.mc2ContactsDenied),
        action: st == ContactsPermission.permanentlyDenied
            ? SnackBarAction(label: t.md1OpenSettings, onPressed: () => src.openSettings())
            : null,
      ));
    }
    return null;
  }
  final list = await src.read();
  if (!context.mounted) return null;
  final rows = [
    for (final c in list)
      if (c.numbers.isNotEmpty) (c.name.trim().isEmpty ? c.numbers.first : c.name.trim(), c.numbers)
  ]..sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
  final pick = await Navigator.of(context).push<(String, List<String>)>(MaterialPageRoute(
      builder: (_) => SharePickerScreen<(String, List<String>)>(
            title: t.mc2ContactFromPhone,
            items: rows,
            nameOf: (r) => r.$1,
            subtitleOf: (r) => r.$2.first,
          )));
  if (pick == null) return null;
  final phones = <String>[];
  for (final n in pick.$2) {
    final c = ContactShare.cleanPhone(n);
    if (c.replaceAll('+', '').length >= 3 && !phones.contains(c)) phones.add(c);
    if (phones.length >= 5) break;
  }
  if (phones.isEmpty) return null;
  return ContactShare(name: pick.$1.length > 80 ? pick.$1.substring(0, 80) : pick.$1, phones: phones);
}

Future<ContactShare?> _pickCircleMember(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  List<Map<String, dynamic>> rows;
  try {
    final r = await api.getJson('/circle/members');
    rows = [
      for (final x in ((r['results'] ?? r['members'] ?? const []) as List).whereType<Map>())
        if ('${x['state'] ?? 'accepted'}' == 'accepted' && x['peer_user_id'] is num)
          x.cast<String, dynamic>()
    ];
  } catch (e) {
    if (context.mounted) _toast(context, t.mc2SendFailed);
    return null;
  }
  if (!context.mounted) return null;
  if (rows.isEmpty) {
    _toast(context, t.mc2CircleEmpty);
    return null;
  }
  final pick = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
      builder: (_) => SharePickerScreen<Map<String, dynamic>>(
            title: t.mc2ContactFromCircle,
            items: rows,
            nameOf: (m) => '${m['name'] ?? ''}',
          )));
  if (pick == null) return null;
  return ContactShare(
      name: '${pick['name'] ?? ''}', uid: (pick['peer_user_id'] as num).toInt());
}

/// Attach → Contact: a phone contact (the contacts disclosure + permission
/// first) or a My Circle member. Returns the server message id or null.
Future<String?> shareContactFlow(BuildContext context,
    {required String chatKind, required int chatId}) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  final from = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          key: const Key('mc2-contact-from-phone'),
          leading: const Icon(Icons.contacts_rounded),
          title: Text(t.mc2ContactFromPhone),
          onTap: () => Navigator.pop(ctx, 'phone'),
        ),
        ListTile(
          key: const Key('mc2-contact-from-circle'),
          leading: const Icon(Icons.people_outline_rounded),
          title: Text(t.mc2ContactFromCircle),
          onTap: () => Navigator.pop(ctx, 'circle'),
        ),
      ]),
    ),
  );
  if (from == null || !context.mounted) return null;
  final c = from == 'phone' ? await _pickPhoneContact(context) : await _pickCircleMember(context);
  if (c == null || !context.mounted) return null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.mc2ContactSendTitle),
      content: ContactCard(contact: c, mine: true, fg: Theme.of(ctx).colorScheme.onSurface),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.md1Cancel)),
        FilledButton(
            key: const Key('mc2-contact-send'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.md1Send)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final lang = _lang(context);
  final fb = t.mc2FallbackContact(
      [c.name, ...c.phones.map((p) => localDigits(p, lang))].where((s) => s.isNotEmpty).join(' '));
  try {
    return await sendShare(api,
        chatKind: chatKind, chatId: chatId, contentType: 'contact', plaintext: encodeContact(c, fb));
  } catch (e) {
    reportNonFatal('mc2_contact_send', e);
    if (context.mounted) _toast(context, t.mc2SendFailed);
    return null;
  }
}

/// A searchable one-pick list (phone contacts / My Circle members).
class SharePickerScreen<T> extends StatefulWidget {
  final String title;
  final List<T> items;
  final String Function(T) nameOf;
  final String Function(T)? subtitleOf;
  const SharePickerScreen(
      {super.key, required this.title, required this.items, required this.nameOf, this.subtitleOf});
  @override
  State<SharePickerScreen<T>> createState() => _SharePickerScreenState<T>();
}

class _SharePickerScreenState<T> extends State<SharePickerScreen<T>> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = _lang(context);
    final q = _q.toLowerCase();
    final shown = widget.items
        .where((x) =>
            q.isEmpty ||
            widget.nameOf(x).toLowerCase().contains(q) ||
            (widget.subtitleOf?.call(x) ?? '').contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: TextField(
            key: const Key('mc2-pick-search'),
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: t.mc2ContactSearch,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(t.mc2ContactNone))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) {
                    final x = shown[i];
                    final name = widget.nameOf(x);
                    final sub = widget.subtitleOf?.call(x);
                    return ListTile(
                      key: Key('mc2-pick-$i'),
                      leading: CircleAvatar(
                          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase())),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: sub == null ? null : Text(localDigits(sub, lang)),
                      onTap: () => Navigator.pop(context, x),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- bubble
/// The card for a decrypted location / contact message, or null when
/// [plaintext] is not a share this build understands.
Widget? shareBubbleBody(String contentType, String plaintext,
    {required bool mine, required Color fg, String? messageId}) {
  if (!kShareKinds.contains(contentType)) return null;
  final s = decodeShare(plaintext);
  if (s == null) return null;
  if (s.location != null) {
    return LocationCard(
        key: ValueKey('mc2-loc-$messageId'),
        share: s.location!,
        mine: mine,
        fg: fg,
        messageId: messageId);
  }
  return ContactCard(key: ValueKey('mc2-contact-$messageId'), contact: s.contact!, mine: mine, fg: fg);
}

// ---------------------------------------------------------------- attach
/// Attach-sheet kinds handled here (not by the md1 file pipeline).
bool isShareAttach(CircleAttachKind k) =>
    k == CircleAttachKind.location ||
    k == CircleAttachKind.liveLocation ||
    k == CircleAttachKind.contact;

/// Run the share flow for an attach-sheet [kind]. Returns the sent id or null.
Future<String?> runShareAttach(BuildContext context, CircleAttachKind kind,
    {required String chatKind, required int chatId}) {
  wireLiveLocation(context.read<AppState>().api);
  if (kind == CircleAttachKind.contact) {
    return shareContactFlow(context, chatKind: chatKind, chatId: chatId);
  }
  return shareLocationFlow(context,
      chatKind: chatKind, chatId: chatId, live: kind == CircleAttachKind.liveLocation);
}
