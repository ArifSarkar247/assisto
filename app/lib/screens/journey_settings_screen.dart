import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import '../widgets/journey_api.dart';
import '../widgets/subs_common.dart' show fmtInt;
import '../services/action_feedback.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Safe Journey settings (items 7, 8, 14, 16, 18). Hosts:
///   - SOS countdown + siren default
///   - Duress PIN setup (item 8) — normal PIN cancels, duress PIN fake-cancels
///   - Wellness check for parents living alone (item 16) — parent opt-in gated
///   - Routine commutes (item 14)
///   - Privacy / auto-delete statement (item 18)
///   - Honest "Available when ___" native trigger rows (item 7)
class JourneySettingsScreen extends StatefulWidget {
  const JourneySettingsScreen({super.key});
  @override
  State<JourneySettingsScreen> createState() => _JourneySettingsScreenState();
}

class _JourneySettingsScreenState extends State<JourneySettingsScreen> {
  int _sosCountdown = 5;
  bool _sirenDefault = false;
  bool _hasDuress = false;

  // wellness
  bool _wellnessEnabled = false;
  bool _parentOptIn = false;
  int _periodHours = 12;
  String _quietStart = '22:00';
  String _quietEnd = '07:00';
  bool _promptOpen = false; // journey100: Assisto asked "Is everything OK?"

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _sosCountdown =
        int.tryParse(await Settings.getString('safety_sos_cd') ?? '') ?? 5;
    _sirenDefault = await Settings.getBool('journey_siren', false);
    _hasDuress = await Settings.getBool('journey_has_duress', false);
    if (!mounted) return;
    try {
      // journey100: the server is the truth for the safety PIN
      _hasDuress = await context.read<AppState>().api.duressPinConfigured();
      await Settings.setBool('journey_has_duress', _hasDuress);
    } catch (_) {
      // best-effort: offline — the last known local flag is shown
    }
    if (!mounted) return;
    try {
      final w = await context.read<AppState>().api.wellnessConfig();
      _promptOpen = w['prompt_open'] == true;
      _wellnessEnabled = w['enabled'] == true;
      _parentOptIn = w['parent_opt_in'] == true;
      _periodHours = (w['period_hours'] as num?)?.toInt() ?? 12;
      _quietStart = (w['quiet_start'] ?? '22:00').toString();
      _quietEnd = (w['quiet_end'] ?? '07:00').toString();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveWellness() async {
    try {
      await context.read<AppState>().api.saveWellnessConfig({
        'enabled': _wellnessEnabled,
        'parent_opt_in': _parentOptIn,
        'period_hours': _periodHours,
        'quiet_start': _quietStart,
        'quiet_end': _quietEnd,
      });
    } catch (_) {
      // q1-seams: a failed save used to be silent — the switch looked on while
      // the server never started the wellness check. Say so and reload the
      // server's real state.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).grpActionFailed)));
      await _load();
    }
  }

  Future<void> _imFine() async {
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.wellnessPing();
      if (!mounted) return;
      setState(() => _promptOpen = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.j100WellnessPinged)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.wellnessPing', e);
    }
  }

  Future<void> _setDuressPin() async {
    final t = AppLocalizations.of(context);
    final pin = TextEditingController();
    final duress = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.duressTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.duressExplain, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          ObscureTextField(
              controller: pin,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.duressNormalPin)),
          ObscureTextField(
              controller: duress,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.duressDuressPin)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      ),
    );
    if (ok != true) return;
    final p = pin.text.trim();
    final d = duress.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final rule = RegExp(r'^[0-9]{4,8}$');
    if (!rule.hasMatch(p) || !rule.hasMatch(d) || p == d) {
      messenger.showSnackBar(SnackBar(content: Text(t.j100PinRule)));
      return;
    }
    try {
      await context.read<AppState>().api.setDuressPin(pin: p, duressPin: d);
      await Settings.setBool('journey_has_duress', true);
      setState(() => _hasDuress = true);
      messenger.showSnackBar(SnackBar(content: Text(t.duressSaved)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyStartFailed)));
    }
  }

  Future<String> _pickTime(String current) async {
    final parts = current.split(':');
    final init = TimeOfDay(
        hour: int.tryParse(parts.first) ?? 22,
        minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0);
    final picked = await showTimePicker(context: context, initialTime: init);
    if (picked == null) return current;
    return '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.journeySettingsTitle)),
          body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.journeySettingsTitle)),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        // SOS
        Text(t.sosSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.safetySosCountdownValue(fmtInt(context, _sosCountdown)))), // qa1
        Slider(
            value: _sosCountdown.toDouble(),
            min: 0,
            max: 30,
            divisions: 30,
            label: '$_sosCountdown',
            onChanged: (v) => setState(() => _sosCountdown = v.round()),
            onChangeEnd: (v) =>
                Settings.setString('safety_sos_cd', '${v.round()}')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.sosSirenDefault),
          subtitle: Text(t.sosSirenDefaultDesc),
          value: _sirenDefault,
          onChanged: (v) {
            setState(() => _sirenDefault = v);
            Settings.setBool('journey_siren', v);
          },
        ),
        const Divider(height: 28),

        // Duress PIN
        Text(t.duressSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_hasDuress ? Icons.lock_rounded : Icons.lock_open_rounded,
              color: _hasDuress ? Colors.green : Colors.grey),
          title: Text(_hasDuress ? t.duressConfigured : t.duressNotSet),
          subtitle: Text(t.duressSubtitle),
          trailing: TextButton(
              onPressed: _setDuressPin,
              child: Text(_hasDuress ? t.edit : t.duressSetUp)),
        ),
        const Divider(height: 28),

        // Wellness check (parents living alone)
        Text(t.wellnessSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        Text(t.wellnessIntro,
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.wellnessEnable),
          value: _wellnessEnabled,
          onChanged: (v) {
            setState(() => _wellnessEnabled = v);
            _saveWellness();
          },
        ),
        if (_wellnessEnabled && _parentOptIn) ...[
          if (_promptOpen)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Text(t.j100WellnessAsk,
                  style: AType.bodyMedium.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600)),
            ),
          FilledButton.icon(
            key: const ValueKey('j100_im_fine'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.favorite_rounded),
            label: Text(t.j100WellnessFine),
            onPressed: _imFine,
          ),
        ],
        if (_wellnessEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.wellnessParentOptIn),
            subtitle: Text(t.wellnessParentOptInDesc),
            value: _parentOptIn,
            onChanged: (v) {
              setState(() => _parentOptIn = v);
              _saveWellness();
            },
          ),
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.wellnessPeriod(_periodHours))),
          Slider(
              value: _periodHours.toDouble(),
              min: 2,
              max: 48,
              divisions: 23,
              label: '$_periodHours',
              onChanged: (v) => setState(() => _periodHours = v.round()),
              onChangeEnd: (_) => _saveWellness()),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.wellnessQuietHours),
            subtitle: Text('$_quietStart – $_quietEnd'),
            trailing: TextButton(
              onPressed: () async {
                final s = await _pickTime(_quietStart);
                final e = await _pickTime(_quietEnd);
                setState(() {
                  _quietStart = s;
                  _quietEnd = e;
                });
                _saveWellness();
              },
              child: Text(t.edit),
            ),
          ),
        ],
        const Divider(height: 28),

        // (NO SHOWPIECES: the native discreet-trigger rows — power button,
        // shake, lock-screen tile, widget, background service — were "coming
        // in a later update" placeholders and are hidden until they ship.)

        // privacy
        Text(t.journeyPrivacySection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(t.journeyPrivacyStatement,
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
